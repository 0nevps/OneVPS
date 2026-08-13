# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/0nevps/OneVPS)](https://github.com/0nevps/OneVPS/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md)

OneVPS 是一个开源的 Linux VPS Xray 节点部署与运维自动化工具。它把安装、配置生成、服务管理和日常维护步骤
集中在一个可审阅的 Bash 工作流中。

目前支持两种部署模式：

- **VLESS + TCP + REALITY + XTLS Vision + uTLS**：独立部署，无需域名或证书。
- **Trojan + WebSocket（Caddy 后端）**：复用 Caddy 的 `:443` 监听与证书，可与其他 Caddy 服务共存。

OneVPS 专注于基于 Xray 的部署，不是通用 VPS 控制面板，也不替代基础设施即代码、防火墙管理、监控或备份系统。

## 为什么需要 OneVPS？

手工运行 Xray 不只是安装一个二进制文件。维护者还需要生成密钥、构建有效配置、创建最小权限的 systemd 服务、
协调端口与防火墙、接入 TLS 终端，并保证后续变更可维护。

OneVPS 将这些步骤保留在可读的 Shell 脚本中，便于运维者在执行前检查系统改动，在其他受支持主机上重复部署，
并通过一个统一入口贡献修复。

## 特性

- **可重复部署**：安装依赖，并根据持久化的节点元数据生成 Xray 配置
- **Xray 官方安装器**：通过 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装或更新核心与 geodata
- **VLESS + TCP + REALITY**：VPS 直连，使用 REALITY 目标站 TLS 握手特征
- **XTLS Vision 与 uTLS**：生成 `xtls-rprx-vision` 用户和包含 `fp=chrome` 的分享链接
- **Trojan + WS（Caddy 后端）**：仅由 Caddy 对外，Xray 入站保持 loopback 监听
- **配置校验**：替换现有配置前先验证新生成的 Xray 配置
- **安全默认值**：随机 UUID、X25519 密钥、short ID、密码和 WebSocket 路径
- **受限路由**：阻断私网地址、BitTorrent 流量，并默认阻断出站 UDP/443
- **最小权限服务**：Xray 使用 `nobody` 运行，仅保留绑定低端口的能力
- **运维能力**：节点与分享链接管理、服务重启、BBR 和可选系统优化
- **网络诊断记录**：可选的采样脚本，持续记录网络与服务指标，使偶发的「连不上」能被定位到服务端或排除服务端

> 旧版 sing-box 节点不会自动迁移。OneVPS 使用 `/usr/local/etc/xray/` 管理 Xray。

## 支持的技术

| 类别 | 支持范围 |
| --- | --- |
| 核心 | [Xray-core](https://github.com/XTLS/Xray-core) |
| 协议 | VLESS、Trojan |
| 传输 | TCP、WebSocket |
| 安全 | REALITY、XTLS Vision、由 Caddy 终结的 TLS |
| 服务管理 | systemd |
| 架构 | amd64、arm64、armv7 |
| 包管理器 | apt、dnf、yum、zypper |

## 快速开始

脚本以 root 权限运行，并会修改系统服务、防火墙规则和可选内核参数。在现有服务器上执行前，请先审阅脚本。

推荐使用带校验文件的正式版本：

```bash
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/onevps.sh
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/SHA256SUMS
sha256sum --check SHA256SUMS
less onevps.sh
sudo bash onevps.sh
```

已确认环境可信时，也可使用便捷命令：

```bash
bash <(curl -fsSL https://github.com/0nevps/OneVPS/releases/latest/download/onevps.sh)
```

便捷命令需要在 root Shell 中运行。首次使用时先选择 `1` 安装或更新 Xray-core，再选择 `2` 添加 Reality 节点，
或选择 `3` 添加 Trojan + WS 节点。

## 菜单

```text
1) Install / update Xray-core
2) Add node - VLESS + Reality + Vision + uTLS
3) Add node - Trojan + WS (behind Caddy)
4) Manage nodes
5) Show all share links
6) Restart service
7) BBR acceleration
8) System optimization
9) Uninstall
0) Exit
```

## VLESS + REALITY

### 默认配置

| 项目 | 默认值 |
| --- | --- |
| 协议 | VLESS |
| 传输 | TCP |
| 传输安全 | REALITY |
| 流控 | `xtls-rprx-vision` |
| uTLS 指纹 | `chrome` |
| 加密 | `none` |
| 端口 | `443`，被占用时使用随机高位端口 |

分享链接格式：

```text
vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=TARGET&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&type=tcp#NAME
```

### REALITY 目标站选择

内置候选：

- `www.cloudflare.com`
- `www.amazon.com`
- `www.paypal.com`
- `www.ebay.com`
- `www.microsoft.com`
- `www.apple.com`
- `www.samsung.com`
- `gateway.icloud.com`
- `www.lovelive-anime.jp`
- `www.wikipedia.org`
- `www.oracle.com`
- `www.netflix.com`

合适的目标站应支持 TLS 1.3 和 HTTP/2，SNI 稳定且证书 SAN 覆盖所填域名，并且从 VPS 网络访问时延迟可接受。

添加或编辑 Reality 节点时，OneVPS 会对内置候选执行多轮 `xray tls ping`，按成功率和平均延迟排序。运维者仍可
手动选择候选或填写自定义域名。如果全部探测失败，脚本会回退到第一个候选并显示警告。

## Trojan + WebSocket（Caddy 后端）

菜单 `3` 创建与 Caddy 已管理服务共享 `443` 端口的 Trojan 节点。

工作方式：

- Xray Trojan 入站**仅监听 `127.0.0.1`**，使用 WebSocket 传输，不终结 TLS。
- Caddy 为独立子域终结 TLS，并把隐藏的 WebSocket 路径反向代理到本地入站。
- 其他 Caddy 站点保持不变。
- 隐藏路径以外的请求返回 HTTP 403，页面位于 `/var/lib/onevps/sites/<域名>/index.html`，可自行编辑。
- 脚本向 Caddyfile 追加带标记的站点块，校验配置后 reload Caddy；reload 失败时会回滚新增块。
- Trojan 节点不修改防火墙规则，Caddy 保持为唯一公网入口。

要求：

- 独立子域的 `A` 或 `AAAA` 记录指向本机
- `80` 和 `443` 端口可达，用于 ACME 和客户端流量
- Caddy；缺失时 OneVPS 通过受支持的软件源安装，或使用静态二进制兜底

分享链接格式：

```text
trojan://PASSWORD@SUBDOMAIN:443?security=tls&sni=SUBDOMAIN&type=ws&host=SUBDOMAIN&path=PATH#NAME
```

## 节点管理

Reality 节点操作：

```text
1) Change port
2) Reset UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target
5) Enable/disable
6) Delete node
```

Trojan 节点操作：

```text
1) Reset password
2) Change domain
3) Change WS path
4) Rebuild Caddy route
5) Enable/disable
6) Delete node
```

`Rebuild Caddy route` 会重新生成受管理的 Caddy 配置块，但不更改节点密码、路径或端口。轮换 Reality 密钥或
重置 Trojan 凭据会使旧客户端链接失效，需要从菜单 `5` 重新导入链接。

## 安全模型

OneVPS 提供多项防御性默认设置，但执行任何 root 级部署脚本前，仍需由运维者审阅，并正常完成服务器安全加固。

- 节点凭据和私钥存储在 `/usr/local/etc/xray/onevps-nodes.json`，并限制文件权限。
- 新生成的运行配置通过校验后才会启用。
- Xray 安装完成后不以 root 身份运行。
- Trojan 入站仅监听 loopback；该模式只有 Caddy 作为公网 TLS 入口。
- 分享链接包含有效凭据，必须按秘密信息处理。
- 安装流程会在运行时下载上游安装器或二进制文件，执行前应根据环境评估网络与上游信任要求。
- OneVPS 不负责配置 SSH 策略、无人值守更新、入侵检测、备份或完整防火墙。

疑似安全漏洞请按照[安全策略](SECURITY.md)私密报告。

## 文件位置

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/xray` | Xray 核心二进制 |
| `/usr/local/etc/xray/config.json` | 生成的 Xray 运行配置 |
| `/usr/local/etc/xray/onevps-nodes.json` | 节点元数据与凭据 |
| `/usr/local/share/xray/` | geoip 与 geosite 数据 |
| `/etc/systemd/system/xray.service` | systemd 服务单元 |
| `/var/log/xray/` | Xray 日志目录 |
| `/var/lib/onevps/sites/<域名>/` | Trojan 子域的可编辑 403 页面 |
| `/usr/local/sbin/onevps-netwatch` | 诊断记录脚本的安装副本 |
| `/etc/onevps-netwatch.conf` | 记录脚本配置，含通知令牌 |
| `/var/log/onevps-netwatch.log` | 采样记录，自动轮转 |
| `/var/lib/onevps-netwatch/` | 计数器基线与告警冷却状态 |

手动管理服务：

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -f
```

配置校验：

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

## 环境要求

- 使用 systemd 的 Linux
- root 权限
- amd64、arm64 或 armv7 架构
- apt、dnf、yum 或 zypper
- `curl`、`jq`、`openssl` 和 CA 证书；缺失依赖会自动安装
- 仅 Trojan + WS 节点需要 Caddy；缺失时自动安装

由于发行版、软件源、Xray 和 Caddy 会各自变化，兼容性支持按最大努力提供。报告兼容性问题时，请附发行版、版本、
架构、包管理器和已脱敏的命令输出。

## BBR 与系统优化

菜单 `7` 启用 BBR，并写入 `/etc/sysctl.d/99-bbr.conf`。

菜单 `8` 为长期运行的 VPS 工作负载应用可选的保守设置：

- 提高 TCP buffer 上限，但不增加每个 socket 的默认分配
- 启用 TCP Fast Open、MTU probing，并提高 backlog
- 设置临时端口范围为 `10000-65535`
- 可创建小型 swap，并限制 journald 磁盘占用
- 可切换 Xray 出站 UDP/443 阻断，默认开启

应用前请确认这些设置适合服务器上的其他工作负载。

## 网络诊断记录

用户报告「14:30 连不上」时，连接报告本身无法回答一个问题：故障在服务端，还是在链路或客户端？偶发问题只有在
故障发生时已有记录才留得下证据，因此 `scripts/onevps-netwatch.sh` 通过 systemd timer 持续采样，生成一条可以
事后查询的时间线。

该脚本是可选的，与节点管理相互独立，`onevps.sh` 不依赖它。

### 安装

```bash
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/onevps-netwatch.sh
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/SHA256SUMS
sha256sum --check SHA256SUMS
less onevps-netwatch.sh
sudo bash onevps-netwatch.sh install
```

安装会把脚本复制到 `/usr/local/sbin/onevps-netwatch`，写入权限 600 的配置文件，并启动每 30 秒采样一次的 timer。
依赖 systemd、root 权限和 iproute2 的 `ss`；`fail2ban-client` 存在时使用，不存在则跳过。

### 命令

| 命令 | 用途 |
| --- | --- |
| `onevps-netwatch status` | 最近 24 小时的结论，采样中断时给出提示 |
| `onevps-netwatch at "14:30"` | 该时刻前后的结论，默认 ±10 分钟，可追加数字调整窗口 |
| `onevps-netwatch report --since 24h` | 指定窗口的结论，时长支持 `s`、`m`、`h`、`d` |
| `onevps-netwatch tail` | 实时跟随原始日志 |
| `onevps-netwatch uninstall` | 移除 timer；加 `--purge` 同时删除日志与配置 |

`status`、`at`、`report` 用大白话回答一个问题：这台服务器有没有责任。三者在各自的时间窗内输出同一份检查清单，
覆盖被监控的服务和各项系统检查。都可以加 `--detail` 改看原始指标。

### 排查一次报障

```bash
onevps-netwatch at "14:30"          # 那个时刻这台服务器有没有问题
onevps-netwatch report --since 6h   # 前后几小时有没有异常
```

每一项检查都会列出，绿的红的都在，不靠省略表达「没问题」。红项说明发生了什么、对用户意味着什么、下一步跑什么：

```text
服务端状态 · 20分钟 / 41 次采样

  caddy 🟢
  sshd 🟢
  xray 🔴 停止 3分钟（14:31-14:34） · 期间连接全部失败
     → journalctl -u xray --since "14:31"
  连接接纳 🔴 队列溢出丢弃 37 个（14:33 起） · 涌入超过处理能力
  连接跟踪表 🟢
  内存 🟢
  磁盘 🟢
  IP 封禁 🟢
  监听端口 🟢

  2 项异常 → 优先排查上面的红项
```

什么都没查到本身就是答案：整个窗口内服务端正常，故障出在链路或客户端——这正是没有记录时最难得出的结论。

### 记录的指标

结论之下，每次采样写一行 `key=value`，无需额外工具即可 grep 和统计：

- conntrack 使用量与上限，以及内核 `table full` 事件
- TCP accept 队列丢弃与溢出、SYN 重传、重传率
- ESTABLISHED、TIME_WAIT、SYN_RECV 套接字数量与监听套接字数
- CPU、内存与根文件系统使用率
- 网卡吞吐与丢包计数
- 内核 OOM 事件与 fail2ban 封禁总数
- 已探测服务的存活状态与主 PID，可暴露无声重启

服务从 `xray`、`caddy`、`nginx`、`sshd`、`ssh`、`fail2ban`、`docker` 中自动探测。需要监控其他单元时，在配置文件中
设置 `MONITOR_UNITS`。

### 告警

在 `/etc/onevps-netwatch.conf` 中设置 `TELEGRAM_TOKEN` 与 `TELEGRAM_CHAT_ID`，或设置 `WEBHOOK_URL`，即可在
conntrack 超过 80%、accept 队列开始丢连接、被监控服务下线或重启、内核发生 OOM、磁盘超过 90% 时收到通知。
告警按类型限流，默认每 30 分钟推送一次；无论是否推送，所有告警都会写入日志。该文件保存通知令牌，创建时权限为
600，请保持不变。

## 卸载

菜单 `9` 删除 Xray 二进制、配置、节点元数据、geodata 和日志目录。

BBR 设置、系统优化文件、swap、Caddy、Caddyfile 和自定义站点内容会被保留，避免删除可能由其他服务共享的主机状态。

诊断记录脚本独立安装，使用 `onevps-netwatch uninstall` 移除。

## 维护与路线图

基础设施自动化需要持续跟进 Linux 发行版和上游组件变化。目前维护重点包括：

- 保持生成的 Xray 与 Caddy 配置兼容受支持的上游版本
- 改善失败处理，使主机变更更容易审计和回滚
- 扩展配置迁移、Caddy 路由和失败路径的自动测试
- 为主机级操作增加一次性跨发行版集成测试
- 记录不同发行版与架构的兼容性结果
- 审查运行时下载和发布完整性控制

CI 会在每次 push 和 pull request 时执行 Bash 语法校验、ShellCheck、配置生成测试和 Markdownlint。

## 测试

轻量测试套件会加载 `onevps.sh`，使用固定节点数据，并且只写入临时目录；不会修改 systemd、防火墙或生产配置。

```bash
bash -n onevps.sh scripts/onevps-netwatch.sh tests/test_onevps.sh
shellcheck --severity=warning onevps.sh scripts/onevps-netwatch.sh tests/test_onevps.sh
bash tests/test_onevps.sh
```

## 版本发布

正式版本包含 `onevps.sh`、`scripts/onevps-netwatch.sh`，以及覆盖两者的 `SHA256SUMS`。发布说明及兼容性相关变更
记录在 [CHANGELOG.md](CHANGELOG.md) 中。

## 参与贡献

欢迎提交问题报告、兼容性结果、文档改进和范围明确的 pull request。提交前请阅读
[CONTRIBUTING.md](CONTRIBUTING.md)。请勿在公开 issue 中包含节点 URL、UUID、密码、私钥或未脱敏的服务器日志。

安全敏感问题必须遵循 [SECURITY.md](SECURITY.md)，不要使用公开 issue。

## 许可证

OneVPS 使用 [MIT License](LICENSE)。

## 免责声明

仅在获得授权的系统和网络中合法使用 OneVPS。运维者负责审阅脚本、遵守所在地法律与服务商条款，并保护生成的凭据。
