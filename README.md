# lxc-subnet-mesh

保留 LXC 容器跨子网互访时的真实源 IP，避免被宿主机 `MASQUERADE` 改写成宿主机 IP。

## Oracle OCI / Always Free 场景

本项目的实际部署环境是 Oracle OCI Always Free：

```text
OCI VCN: 10.0.0.0/16（示例）
└── 子网: 10.0.0.0/24
    ├── 宿主机 A: 10.0.0.87   lxcbr0 = 10.2.0.1/24   容器 10.2.0.2
    └── 宿主机 B: 10.0.0.2    lxcbr0 = 10.1.0.1/24   容器 10.1.0.x
```

两台 OCI 实例位于同一个 `10.0.0.0/24` 子网，已经互通。把每台 Always Free 实例切成多个 LXC 容器，再为两个 LXC 子网添加静态路由，就可以让跨主机的容器直接互访。这样一台免费实例可以承载多个容器，两台实例就能组成一个小型多节点容器环境。

> Always Free 的具体额度、实例形状和可用区以 Oracle 官方条款为准。

### OCI IPv4 配置要点

1. **VCN / 子网**
   - VCN 可规划为 `10.0.0.0/16`，子网为 `10.0.0.0/24`。
   - 实例的 `ens3` 获取子网内的私有 IPv4，例如 `10.0.0.87`、`10.0.0.2`。
   - 默认网关是子网网关，例如 `10.0.0.1`。

2. **安全列表 / NSG**
   - 两台宿主机之间需要放行流量。
   - LXC 容器的源/目的地址是 `10.2.0.0/24` 和 `10.1.0.0/24`，因此安全列表或 NSG 要允许这两个网段互访，例如：
     - 入站：源 `10.1.0.0/24`，目的 `10.2.0.0/24`，协议按需（全部 / TCP / ICMP）
     - 入站：源 `10.2.0.0/24`，目的 `10.1.0.0/24`，协议按需
   - 出站方向同样按需放行。安全列表是有状态的，回程流量会自动放行。
   - SSH、ICMP 等管理流量按需放行。

3. **关闭 VNIC 的源/目的检查**
   - OCI 默认会对 VNIC 做源地址检查。宿主机转发 LXC 流量时，源 IP 是 `10.2.0.x` 或 `10.1.0.x`，不是 VNIC 自己的私有 IP，可能被丢弃。
   - 在 OCI 控制台或 CLI 关闭源/目的检查：
     ```bash
     oci network vnic update \
       --vnic-id <vnic-ocid> \
       --skip-source-dest-check true
     ```
     控制台路径：实例详情 → 附加的 VNIC → 编辑 → 勾选 “Skip source/destination check”。
   - 这是 LXC 子网路由能通的关键。

4. **宿主机静态路由**
   ```bash
   # 宿主机 A: 10.0.0.87
   ip route add 10.1.0.0/24 via 10.0.0.2

   # 宿主机 B: 10.0.0.2
   ip route add 10.2.0.0/24 via 10.0.0.87
   ```
   两台宿主机在同一子网内，VCN 路由表不需要为 `10.1.0.0/24` / `10.2.0.0/24` 添加条目；流量通过 ARP 发给对端宿主机，再由对端宿主机转发给 LXC 网桥。

5. **宿主机开启 IPv4 转发**
   ```bash
   sysctl -w net.ipv4.ip_forward=1
   ```
   `lxc-net` 通常会自动开启；如果没有，需要持久化到 `/etc/sysctl.d/`。

6. **LXC 网桥**
   ```text
   宿主机 A: lxcbr0 10.2.0.1/24，容器 10.2.0.2
   宿主机 B: lxcbr0 10.1.0.1/24，容器 10.1.0.x
   ```
   容器默认路由指向各自的 `lxcbr0` 网关。

完成以上配置后，容器之间可以互通。但 `lxc-net` 默认的 `MASQUERADE` 会把跨子网流量的源 IP 改写成宿主机 IP，这正是本脚本要解决的问题。

## 问题现象

两台 OCI 宿主机上的 LXC 子网通过静态路由互通后，容器之间可以 ping 通，但 B 侧应用看到的来源 IP 是主机 A 的 `10.0.0.87`，而不是容器 A 的 `10.2.0.2`。

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
