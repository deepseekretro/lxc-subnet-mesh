#!/usr/bin/env bash
#
# lxc-no-nat.sh
#
# 解决 LXC 默认 MASQUERADE 把容器访问“已路由互通的其它 LXC 子网”的源 IP
# 改写成宿主机 IP 的问题。
#
# 原理：
#   lxc-net 会生成 nft 表 ip lxc，链 postrouting 中有一条
#       ip saddr <本机LXC子网> ip daddr != <本机LXC子网> masquerade
#   本脚本在该链顶部插入一条带 comment 的 return 规则：
#       ip saddr { 本机LXC子网 } ip daddr { 本机LXC子网 + 对端已路由私网 } return
#   从而只对“LXC 到 LXC”的流量保留真实源 IP，访问公网/局域网仍然 NAT。
#
# 用法：
#   sudo ./lxc-no-nat.sh                 # 一键修改本机（自动检测 LXC 子网和对端路由）
#   sudo ./lxc-no-nat.sh --dry-run       # 只打印将要做的修改
#   sudo ./lxc-no-nat.sh --status        # 查看检测结果和当前规则
#   sudo ./lxc-no-nat.sh --revert        # 撤销本脚本做的修改
#   sudo ./lxc-no-nat.sh --peer 10.1.0.0/24
#   sudo ./lxc-no-nat.sh --remote root@10.0.0.2
#   sudo ./lxc-no-nat.sh --remote root@10.0.0.2 --dry-run
#
# 说明：
#   - 自动检测对端子网的方法：读取本机路由表中“非默认、带 via 的 RFC1918 网段”。
#     如果你的对端网段不是通过路由表体现的，请用 --peer 显式指定。
#   - 仅支持 IPv4 和 nftables 模式的 lxc-net（LXC 5.x 默认）。
#

set -euo pipefail

PROG=${0##*/}
HELPER=/usr/local/sbin/lxc-no-nat.sh
CONF=/etc/lxc/no-nat.conf
DROPIN_DIR=/etc/systemd/system/lxc-net.service.d
DROPIN=$DROPIN_DIR/10-no-nat.conf
NFT_TABLE=ip
NFT_TABLE_NAME=lxc
NFT_CHAIN=postrouting
TAG=lxc-no-nat

MODE=apply
DRY_RUN=0
PERSIST=1
RUNTIME_ONLY=0
REMOTE=""
PEER_SET=0
LOCAL_SET=0
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

declare -a LOCALS=()
declare -a PEERS=()
declare -a DST=()
declare -a REST=()

die()  { echo "错误: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }

usage() {
    cat <<'EOF'
lxc-no-nat.sh - 保留 LXC 跨子网访问时的真实源 IP

用法:
  sudo ./lxc-no-nat.sh                 一键修改本机（自动检测 LXC 子网和对端路由）
  sudo ./lxc-no-nat.sh --dry-run       只打印将要做的修改
  sudo ./lxc-no-nat.sh --status        查看检测结果和当前规则
  sudo ./lxc-no-nat.sh --revert        撤销本脚本做的修改
  sudo ./lxc-no-nat.sh --peer 10.1.0.0/24
  sudo ./lxc-no-nat.sh --local 10.2.0.0/24
  sudo ./lxc-no-nat.sh --remote root@10.0.0.2
  sudo ./lxc-no-nat.sh --remote root@10.0.0.2 --dry-run

说明:
  - 自动检测对端子网：读取路由表中“非默认、带 via 的 RFC1918 网段”。
    如果对端网段不是通过路由表体现的，请用 --peer 显式指定。
  - 仅支持 IPv4 和 nftables 模式的 lxc-net（LXC 5.x 默认）。
EOF
}

is_ipv4_cidr() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

is_private_cidr() {
    local ip=${1%/*}
    case "$ip" in
        10.*|192.168.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        *) return 1 ;;
    esac
}

dedupe() { awk 'NF && !seen[$0]++'; }

join_by() {
    local IFS="$1"; shift
    printf '%s' "$*"
}

add_list() {
    local -n _arr=$1
    local IFS=,
    local _x
    for _x in $2; do
        [ -n "$_x" ] && _arr+=("$_x")
    done
}

clean_array() {
    local -n _arr=$1
    local -a _tmp=()
    local _x
    for _x in "${_arr[@]}"; do
        [ -n "$_x" ] && _tmp+=("$_x")
    done
    _arr=("${_tmp[@]}")
}

# ---------------------------------------------------------------------------
# 参数解析（先摘出 --remote，剩余参数在远程机器上再解析一遍）
# ---------------------------------------------------------------------------
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    a=${args[$i]}
    case "$a" in
        --remote)
            i=$((i + 1))
            [ $i -lt ${#args[@]} ] || die "--remote 需要一个参数，例如 root@10.0.0.2"
            REMOTE=${args[$i]}
            ;;
        --remote=*) REMOTE=${a#*=} ;;
        *)          REST+=("$a") ;;
    esac
    i=$((i + 1))
done

set -- "${REST[@]}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)      DRY_RUN=1 ;;
        --revert)       MODE=revert ;;
        --status)       MODE=status ;;
        --runtime-only) RUNTIME_ONLY=1; PERSIST=0 ;;
        --no-persist)   PERSIST=0 ;;
        --peer)
            shift
            [ $# -gt 0 ] || die "--peer 需要参数，例如 10.1.0.0/24"
            add_list PEERS "$1"; PEER_SET=1
            ;;
        --peer=*)  add_list PEERS "${1#*=}"; PEER_SET=1 ;;
        --local)
            shift
            [ $# -gt 0 ] || die "--local 需要参数，例如 10.2.0.0/24"
            add_list LOCALS "$1"; LOCAL_SET=1
            ;;
        --local=*) add_list LOCALS "${1#*=}"; LOCAL_SET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知参数: $1（--help 查看用法）" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# 远程模式：上传自身到远端临时文件，再用 root/sudo 执行
# ---------------------------------------------------------------------------
run_remote() {
    [ -f "$0" ] || die "远程模式需要以文件方式运行本脚本"
    command -v ssh >/dev/null 2>&1 || die "未找到 ssh"

    info "上传脚本到 $REMOTE ..."
    local tmp rc=0
    tmp=$(ssh "${SSH_OPTS[@]}" "$REMOTE" 'mktemp /tmp/lxc-no-nat.XXXXXX.sh') \
        || die "无法连接 $REMOTE"

    if ! ssh "${SSH_OPTS[@]}" "$REMOTE" "cat > '$tmp'" < "$0"; then
        ssh "${SSH_OPTS[@]}" "$REMOTE" "rm -f '$tmp'" || true
        die "上传脚本失败"
    fi
    ssh "${SSH_OPTS[@]}" "$REMOTE" "chmod 755 '$tmp'"

    local cmd="'$tmp'" a
    for a in "${REST[@]}"; do
        cmd+=" $(printf '%q' "$a")"
    done

    if ssh "${SSH_OPTS[@]}" "$REMOTE" 'test "$(id -u)" -eq 0'; then
        ssh "${SSH_OPTS[@]}" "$REMOTE" "$cmd" || rc=$?
    else
        info "远端非 root，尝试 sudo -n ..."
        ssh "${SSH_OPTS[@]}" "$REMOTE" "sudo -n $cmd" || rc=$?
        [ $rc -eq 0 ] || warn "远端 sudo 失败；请使用 root 或配置免密 sudo"
    fi

    ssh "${SSH_OPTS[@]}" "$REMOTE" "rm -f '$tmp'" || true
    return $rc
}

if [ -n "$REMOTE" ]; then
    run_remote
    exit $?
fi

[ "$(id -u)" -eq 0 ] || die "请用 root 运行（或 sudo）"

# ---------------------------------------------------------------------------
# 检测
# ---------------------------------------------------------------------------
detect_locals() {
    local -a found=()
    local n br

    # 1) 最权威：lxc-net 生成的 nft 规则
    while IFS= read -r n; do
        [ -n "$n" ] && found+=("$n")
    done < <(
        nft list table ip lxc 2>/dev/null |
        sed -n 's/.*ip saddr \([0-9]\{1,3\}\(\.[0-9]\{1,3\}\)\{3\}\/[0-9]\{1,2\}\) ip daddr != .*masquerade.*/\1/p'
    )

    # 2) /etc/default/lxc-net
    if [ -r /etc/default/lxc-net ]; then
        n=$( (. /etc/default/lxc-net 2>/dev/null; printf '%s' "${LXC_NETWORK:-}") ) || true
        [ -n "$n" ] && found+=("$n")
    fi

    # 3) lxcbr* 网桥上的直连路由
    for br in /sys/class/net/lxcbr*; do
        [ -e "$br" ] || continue
        br=${br##*/}
        n=$(ip -4 route show dev "$br" scope link 2>/dev/null | awk 'NR==1{print $1}') || true
        [ -n "$n" ] && found+=("$n")
    done

    printf '%s\n' "${found[@]}" | dedupe
}

detect_peers() {
    local locals_str=$1
    ip -4 route show | while IFS= read -r line; do
        set -- $line
        local dest=$1
        case "$dest" in
            default|0.0.0.0/0) continue ;;
        esac
        [[ $line == *" via "* ]] || continue
        [[ $line == *" dev lo"* ]] && continue
        is_private_cidr "$dest" || continue
        printf '%s\n' "$locals_str" | grep -qxF "$dest" && continue
        echo "$dest"
    done | dedupe
}

# ---------------------------------------------------------------------------
# nft 操作
# ---------------------------------------------------------------------------
ensure_table() {
    nft list table "$NFT_TABLE" "$NFT_TABLE_NAME" >/dev/null 2>&1 \
        || die "未找到 nft 表 ${NFT_TABLE} ${NFT_TABLE_NAME}，请确认 lxc-net 正在运行"
}

delete_managed_rules() {
    local line h
    while IFS= read -r line; do
        [[ $line == *"return"* ]] || continue
        [[ $line == *"masquerade"* ]] && continue

        # 删除本脚本带 comment 的规则；同时清理旧版本留下的无 comment 的 return 规则
        if [[ $line == *"$TAG"* || $line != *'comment "'* ]]; then
            h=$(sed -n 's/.*# handle \([0-9]\+\)$/\1/p' <<< "$line")
            [ -n "$h" ] || continue
            if [ "$DRY_RUN" = 1 ]; then
                info "将删除旧规则 handle $h"
            else
                nft delete rule "$NFT_TABLE" "$NFT_TABLE_NAME" "$NFT_CHAIN" handle "$h"
            fi
        fi
    done < <(nft -a list chain "$NFT_TABLE" "$NFT_TABLE_NAME" "$NFT_CHAIN" 2>/dev/null || true)
}

build_dst() {
    DST=()
    local x
    for x in "${LOCALS[@]}" "${PEERS[@]}"; do
        DST+=("$x")
    done
    mapfile -t DST < <(printf '%s\n' "${DST[@]}" | dedupe)
}

apply_rule() {
    local src dst
    src=$(join_by ', ' "${LOCALS[@]}")
    dst=$(join_by ', ' "${DST[@]}")

    info "本机 LXC 子网 : $src"
    info "豁免 NAT 的目的: $dst"

    if [ "$DRY_RUN" = 1 ]; then
        info "将执行: nft insert rule ${NFT_TABLE} ${NFT_TABLE_NAME} ${NFT_CHAIN} ip saddr { $src } ip daddr { $dst } counter return comment \"$TAG\""
        return 0
    fi

    # 先做语法校验，避免删掉旧规则后插入失败
    if ! nft -c insert rule "$NFT_TABLE" "$NFT_TABLE_NAME" "$NFT_CHAIN" \
            ip saddr "{ $src }" ip daddr "{ $dst }" counter return comment "$TAG" 2>/dev/null; then
        die "nft 规则校验失败，未做修改"
    fi

    delete_managed_rules
    nft insert rule "$NFT_TABLE" "$NFT_TABLE_NAME" "$NFT_CHAIN" \
        ip saddr "{ $src }" ip daddr "{ $dst }" counter return comment "$TAG"
    info "已插入 nft 规则"
}

# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------
persist() {
    [ "$PERSIST" = 1 ] || return 0
    [ "$RUNTIME_ONLY" = 1 ] && return 0

    if [ "$DRY_RUN" = 1 ]; then
        info "将写入配置: $CONF"
        info "将写入 drop-in: $DROPIN"
        info "将安装脚本: $HELPER"
        return 0
    fi

    mkdir -p "$(dirname "$CONF")" "$DROPIN_DIR"

    {
        echo "# Generated by $PROG at $(date -Is)"
        echo "LOCAL_SUBNETS=\"${LOCALS[*]}\""
        echo "PEER_SUBNETS=\"${PEERS[*]}\""
    } > "$CONF"

    if [ ! -f "$HELPER" ] || [ "$(readlink -f "$0")" != "$(readlink -f "$HELPER")" ]; then
        install -m 0755 "$0" "$HELPER"
    fi

    cat > "$DROPIN" <<EOF
[Service]
ExecStartPost=$HELPER --runtime-only
EOF

    systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload 失败"
    info "已持久化: $CONF"
    info "已持久化: $DROPIN"
}

# ---------------------------------------------------------------------------
# status / revert
# ---------------------------------------------------------------------------
show_status() {
    echo "== 本机检测到的 LXC 子网 =="
    detect_locals | sed 's/^/  /'
    echo "== 自动检测到的对端已路由私网（候选） =="
    local l
    l=$(detect_locals)
    detect_peers "$l" | sed 's/^/  /'
    echo "== 持久化配置 $CONF =="
    if [ -r "$CONF" ]; then
        sed 's/^/  /' "$CONF"
    else
        echo "  (无)"
    fi
    echo "== 当前 nft 规则 =="
    nft -a list chain "$NFT_TABLE" "$NFT_TABLE_NAME" "$NFT_CHAIN" 2>/dev/null | sed 's/^/  /' \
        || echo "  (未找到 ${NFT_TABLE} ${NFT_TABLE_NAME} 表)"
}

do_revert() {
    ensure_table
    delete_managed_rules
    if [ "$DRY_RUN" = 1 ]; then
        info "将删除 $CONF, $DROPIN, $HELPER 并 daemon-reload"
    else
        rm -f "$CONF" "$DROPIN" "$HELPER"
        rmdir "$DROPIN_DIR" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
    info "已撤销本脚本的修改（lxc-net 自带的 MASQUERADE 规则保留）"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$MODE" in
    status)
        show_status
        exit 0
        ;;
    revert)
        do_revert
        exit 0
        ;;
esac

ensure_table

# 开机时由 lxc-net 的 ExecStartPost 调用：优先读取已保存的配置，避免路由未就绪
if [ "$RUNTIME_ONLY" = 1 ] && [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
    read -ra LOCALS <<< "${LOCAL_SUBNETS:-}"
    read -ra PEERS  <<< "${PEER_SUBNETS:-}"
fi

clean_array LOCALS
clean_array PEERS

if [ "$LOCAL_SET" = 0 ] && [ ${#LOCALS[@]} -eq 0 ]; then
    mapfile -t LOCALS < <(detect_locals)
    clean_array LOCALS
fi

[ ${#LOCALS[@]} -gt 0 ] || die "未检测到 LXC 子网，请用 --local 10.2.0.0/24 指定"

if [ "$PEER_SET" = 0 ] && [ ${#PEERS[@]} -eq 0 ]; then
    mapfile -t PEERS < <(detect_peers "$(printf '%s\n' "${LOCALS[@]}")")
    clean_array PEERS
fi

for x in "${LOCALS[@]}"; do
    is_ipv4_cidr "$x" || die "无效的本地子网: $x"
done
for x in "${PEERS[@]}"; do
    is_ipv4_cidr "$x" || die "无效的对端子网: $x"
done

if [ ${#PEERS[@]} -eq 0 ]; then
    warn "未检测到已路由的私网段（peer）。"
    warn "如果对端 LXC 子网不是通过路由表体现的，请用 --peer 10.1.0.0/24 指定。"
    if [ ${#LOCALS[@]} -lt 2 ]; then
        info "没有需要豁免的跨网段流量，退出。"
        exit 0
    fi
fi

build_dst
apply_rule
persist

if [ "$DRY_RUN" = 1 ]; then
    info "dry-run 完成，未修改系统。"
else
    info "完成。可用 --status 查看结果。"
fi
