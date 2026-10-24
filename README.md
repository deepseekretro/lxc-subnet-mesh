# lxc-subnet-mesh

保留 LXC 容器跨子网互访时的真实源 IP，避免被宿主机 `MASQUERADE` 改写成宿主机 IP。

## 背景

两台宿主机各自运行 LXC：

```text
主机 A: 10.0.0.87   lxcbr0 = 10.2.0.1/24   容器 10.2.0.2
主机 B: 10.0.0.2    lxcbr0 = 10.1.0.1/24   容器 10.1.0.x
```

两台主机通过静态路由互通：

```bash
# 主机 A
ip route add 10.1.0.0/24 via 10.0.0.2

# 主机 B
ip route add 10.2.0.0/24 via 10.0.0.87
```

此时容器之间能 ping 通，但 B 侧应用看到的来源 IP 是主机 A 的 `10.0.0.87`，而不是容器 A 的 `10.2.0.2`。

## 原因

`lxc-net` 默认会创建如下 nftables 规则：

```nft
table ip lxc {
    chain postrouting {
        ip saddr 10.2.0.0/24 ip daddr != 10.2.0.0/24 counter masquerade
    }
}
```

这条规则会把所有“目的地址不是本机 LXC 子网”的流量都做 NAT，包括已经通过路由互通的 `10.1.0.0/24`。

手动在 iptables 里加 `! -d 10.0.0.0/8` 是无效的，因为 LXC 5.x 使用的是独立的 nft 表 `ip lxc`，两条链互不影响。

## 解决方案

在 `ip lxc postrouting` 链顶部插入一条带 comment 的 `return` 规则：

```nft
ip saddr { 10.2.0.0/24 } ip daddr { 10.1.0.0/24, 10.2.0.0/24 } counter return comment "lxc-no-nat"
```

效果：

- 容器访问另一个 LXC 子网：保留真实源 IP
- 容器访问公网 / 普通局域网：仍然 `MASQUERADE`，不受影响

## 功能

- 自动检测本机 LXC 子网
- 自动检测路由表中已路由的对端 RFC1918 网段
- 自动插入 / 更新 nft 规则，幂等
- 自动持久化，重启后仍然生效
- 支持本机执行和 SSH 远程执行
- 支持 `--dry-run`、`--status`、`--revert`
- 支持 `--peer` / `--local` 手动覆盖自动检测结果

## 环境要求

- Linux + systemd
- LXC 5.x，`lxc-net` 使用 nftables 模式
- IPv4
- root 权限
- 远程模式额外要求：
  - SSH 密钥登录（脚本使用 `BatchMode=yes`）
  - 远端 root，或免密 `sudo -n`

## 快速开始

```bash
# 1. 先预览
sudo ./lxc-no-nat.sh --dry-run

# 2. 本机应用
sudo ./lxc-no-nat.sh

# 3. 查看结果
sudo ./lxc-no-nat.sh --status
```

预期输出：

```text
[*] 本机 LXC 子网 : 10.2.0.0/24
[*] 豁免 NAT 的目的: 10.2.0.0/24,10.1.0.0/24
[*] 已插入 nft 规则
[*] 已持久化: /etc/lxc/no-nat.conf
[*] 已持久化: /etc/systemd/system/lxc-net.service.d/10-no-nat.conf
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `--dry-run` | 只打印将要执行的修改，不落盘 |
| `--status` | 显示检测到的 LXC 子网、对端网段、持久化配置和当前 nft 规则 |
| `--revert` | 删除脚本插入的规则、持久化配置和 helper |
| `--peer CIDR[,CIDR]` | 手动指定对端网段（覆盖自动检测） |
| `--local CIDR[,CIDR]` | 手动指定本机 LXC 子网（覆盖自动检测） |
| `--no-persist` | 只修改运行时规则，不写持久化文件 |
| `--runtime-only` | 仅供 `lxc-net` 的 `ExecStartPost` 调用，不写持久化 |
| `--remote [user@]host` | 通过 SSH 在远端执行 |
| `-h, --help` | 显示帮助 |

示例：

```bash
# 对端网段自动检测不到时
sudo ./lxc-no-nat.sh --peer 10.1.0.0/24

# 多个对端网段
sudo ./lxc-no-nat.sh --peer 10.1.0.0/24,10.3.0.0/24

# 手动指定本机 LXC 子网
sudo ./lxc-no-nat.sh --local 10.2.0.0/24 --peer 10.1.0.0/24

# 远程执行
sudo ./lxc-no-nat.sh --remote root@10.0.0.2 --dry-run
sudo ./lxc-no-nat.sh --remote root@10.0.0.2
```

## 自动检测逻辑

### 本机 LXC 子网

按顺序尝试：

1. `nft list table ip lxc` 中的 `ip saddr ... ip daddr != ... masquerade`
2. `/etc/default/lxc-net` 的 `LXC_NETWORK`
3. `lxcbr*` 网桥上的直连路由

### 对端已路由私网

扫描 `ip -4 route show`，筛选：

- 不是 `default`
- 包含 ` via `
- 属于 RFC1918：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`
- 不是本机 LXC 子网
- 不是 `dev lo`

如果对端网段不在主路由表中（策略路由、直连、VPN 等），请用 `--peer` 指定。

## 持久化文件

| 文件 | 作用 |
| --- | --- |
| `/usr/local/sbin/lxc-no-nat.sh` | 安装后的脚本 |
| `/etc/lxc/no-nat.conf` | 保存检测到的 `LOCAL_SUBNETS` 和 `PEER_SUBNETS` |
| `/etc/systemd/system/lxc-net.service.d/10-no-nat.conf` | `lxc-net` 启动后自动补规则 |

`lxc-net` 每次启动都会 flush `ip lxc` 表，所以通过 `ExecStartPost` 重新插入规则。

## 验证

### 抓包看源 IP

在本地容器所在宿主机执行：

```bash
lxc-attach -n lxc-001 -- tcpdump -ni eth0 -c 5 'tcp port 9000'
```

在远端容器内执行：

```bash
telnet 10.2.0.2 9000
# 或者
bash -c 'echo > /dev/tcp/10.2.0.2/9000'
```

期望看到：

```text
IP 10.1.0.23.45678 > 10.2.0.2.9000: Flags [S]
```

如果看到 `10.0.0.2`，说明远端 NAT 还没修复。

### 用 ss 看对端地址

```bash
lxc-attach -n lxc-001 -- ss -tn '( sport = :9000 )'
```

`Peer Address:Port` 列就是来源 IP。

### 确认公网仍然 NAT

```bash
lxc-attach -n lxc-001 -- ping -c 2 8.8.8.8
tcpdump -ni ens3 -c 4 'icmp and host 8.8.8.8'
```

应看到源地址是宿主机 `ens3` 的地址。

## 远端部署

### 方式一：脚本远程执行

```bash
sudo ./lxc-no-nat.sh --remote root@10.0.0.2 --dry-run
sudo ./lxc-no-nat.sh --remote root@10.0.0.2
```

脚本会：

1. 通过 SSH 上传自身到远端 `/tmp`
2. 在远端执行
3. 执行完删除临时文件
4. 远端脚本会自动检测 `10.1.0.0/24` 和 `10.2.0.0/24`

### 方式二：手动拷贝

```bash
scp lxc-no-nat.sh root@10.0.0.2:/root/
ssh root@10.0.0.2
cd /root
./lxc-no-nat.sh --dry-run
./lxc-no-nat.sh
```

## 回滚

```bash
sudo ./lxc-no-nat.sh --revert
```

会删除：

- 脚本插入的 nft `return` 规则
- `/etc/lxc/no-nat.conf`
- `/etc/systemd/system/lxc-net.service.d/10-no-nat.conf`
- `/usr/local/sbin/lxc-no-nat.sh`

`lxc-net` 自带的 `MASQUERADE` 规则会保留，网络恢复默认 NAT 行为。

## 注意事项

1. 只支持 IPv4 + nftables 模式的 `lxc-net`。旧版 iptables 模式不支持。
2. 自动检测对端网段依赖主路由表；策略路由 / 直连场景请用 `--peer`。
3. 访问 `10.0.0.0/24` 等普通局域网默认仍然 NAT。如果局域网路由器有回程路由，可以显式加 `--peer 10.0.0.0/24`，但要先确认回程可达。
4. 远端 SSH 使用 `BatchMode=yes`，需要提前配置密钥登录。
5. 如果容器同时配置了静态 IP 和 DHCP，可能出现两个同网段 IP，导致源 IP 不确定。建议在容器内关闭 DHCP。例如 systemd-networkd：

   ```ini
   # /etc/systemd/network/eth0.network
   [Match]
   Name=eth0

   [Network]
   Address=10.2.0.2/24
   Gateway=10.2.0.1
   DHCP=false
   ```

   然后：

   ```bash
   networkctl reload
   networkctl reconfigure eth0
   ```

6. 修改 nft 规则需要 root；脚本在非 root 时会直接退出。

## 工作流程

```text
lxc-net start
    │
    ├─ 创建 nft 表 ip lxc
    │     └─ ip saddr <LXC子网> ip daddr != <LXC子网> masquerade
    │
    └─ ExecStartPost
          └─ lxc-no-nat.sh --runtime-only
                ├─ 读取 /etc/lxc/no-nat.conf
                └─ 在链顶部插入 return 规则
```

## 文件结构

```text
.
├── README.md
└── lxc-no-nat.sh
```
