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
- **受限路由**：阻断私网地址和 BitTorrent 流量
- **最小权限服务**：Xray 使用 `nobody` 运行，仅保留绑定低端口的能力
- **运维能力**：节点与分享链接管理、服务重启、BBR 和可选 TCP 优化

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

稳定版本 tag 通过 CI 验证后自动发布脚本和校验文件。补发已有版本见[发布流程](CONTRIBUTING.md#releases)。

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

菜单按任务分组，主菜单与子菜单的原有编号保持不变。
用户和出站管理位于 `4`，选中节点后分别选择 `7` 或 `8`。
删除和卸载操作单独放在 **Danger zone** 分组，保留原有确认提示。

```text
Xray setup:
 1) Install / update Xray-core

Nodes / share links:
 2) Add node - VLESS + Reality + Vision + uTLS
 3) Add node - Trojan + WS (behind Caddy)
 4) Manage nodes / users / outbound
 5) Show default node share links

Relay:
10) Manage Realm relay (independent of Xray)

Service / network:
 6) Restart Xray service
 7) Enable BBR / show status
 8) TCP optimization

Danger zone:
 9) Uninstall Xray (keep Realm / Caddy)

 0) Exit
```

## 节点出站

在单节点管理菜单中选择 `8`（Set node outbound），先选择**所有用户**或**指定用户**，再设置显式
**直连**、粘贴一条代理链接（输入可见，凭据会显示在屏幕上），或恢复默认设置。

- **指定用户**：选择当前节点的一个或多个用户，也可选择默认客户端；仅修改所选用户的出口。
  恢复默认会删除所选用户的独立出口，使其重新继承节点出口。
- **所有用户**：统一设置本节点出口，并清除本节点全部用户（含默认客户端）的独立出口。
  后续新增用户也继承该出口。恢复默认会清除节点出口及全部用户覆盖，回到默认直连。
- 出口优先级为安全阻断、用户独立出口、节点出口、默认直连。显式直连可覆盖节点代理出口。
  操作仅影响当前节点，不会修改其他节点的用户或出口。

支持的链接：

- **Shadowsocks：** SIP002，支持 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`；
  userinfo 可以是 Base64URL 编码的 `method:password`，或分别进行百分号编码的明文形式。
  不支持 SS2022、插件或旧式整条链接 Base64 编码。
- **VLESS：** TCP + Reality，以及 TCP / WebSocket / gRPC + TLS，包含 OneVPS 自身生成的
  TCP + Reality + Vision 链接。不支持的传输、加密选项和不安全 TLS 选项会明确拒绝，不会静默忽略。
- **SOCKS5：** `socks5://host:port` 或 `socks5://username:password@host:port`。
  凭据中的保留字符需要百分号编码；不支持 `socks://` 和 `socks5h://`。

VLESS 参数白名单为 `encryption`、`type`、`security`、`flow`、`sni`、`fp`、`pbk`、`sid`、
`spx`、`host`、`path`、`serviceName`、`mode`、`alpn`，并须与所选传输匹配。
Reality 必须提供 `sni`、`fp`、`pbk`、`sid`；TLS 不接受 Reality 专用字段。
`type` 默认为 `tcp`，`encryption` 默认为 `none`，`flow` 默认为空。Vision 仅限 TCP；
gRPC 的 `mode` 支持 `gun` 或 `multi`；TLS 的 `alpn` 支持 `h2` 和／或 `http/1.1`。
WebSocket 的 `path` 按字面路径处理，不作为 early-data 配置。未知或重复参数会拒绝。

上述格式支持域名、IPv4、方括号 IPv6、显式端口及可选 `#备注`。
例如 `socks5://test:example%3Apassword@proxy.example.com:1080#Example` 使用虚构测试凭据。
每次仅导入一条链接，不支持订阅或任意 Xray JSON 编辑。

原有私网和 BitTorrent 阻断规则**优先于**出站选择。代理失败不会自动回退直连。
SOCKS5 不加密流量或凭据，请仅通过可信或受保护的链路使用；UDP 是否可用还取决于上游协议和服务端，
不能仅凭链接合法就保证可用。

出站变更要求已安装 Xray，且候选配置通过校验。应用时保留备份并重启 Xray，可能启动原本停止的服务。
检测到启用失败时，会恢复原元数据和配置，并尝试恢复原服务状态。恢复失败会单独报错；
这不是文件替换期间断电安全的保证。非法链接或校验失败不会修改在线文件。
规范化代理配置仍包含秘密，元数据、生成配置及恢复备份均须妥善保护；上游凭据不会附加到客户端分享链接。
旧版脚本可能忽略出站配置并在重新生成时恢复直连；需要保留指定出口时，不要降级后重新生成配置。

独立内核检查必须指定真实二进制，缺少二进制会失败：

```bash
XRAY_TEST_BIN=/absolute/path/to/xray bash tests/test_xray_outbounds.sh
```

CI 使用 Xray `26.3.27` 执行此检查。配置通过不代表上游可达，仍需单独验证流量确实经过预期出口。

## 节点用户管理

在单节点管理菜单中管理该节点的用户：添加用户、删除用户及查看独立分享链接。
用户只属于当前节点，不存在全局账号或跨节点分配；不同节点可使用相同用户名。
新增 Reality 用户拥有独立 UUID，新增 Trojan 用户拥有独立密码，默认继承节点出口。
同一节点内的用户名、用户 ID 和凭据不得重复，凭据也不得与默认客户端冲突。

原有默认客户端及其分享链接保持不变。默认客户端是保留项，不能通过用户删除菜单删除，
其凭据仍由节点原有重置入口管理。删除新增用户需要确认；应用成功后，该用户的凭据和链接失效，
其独立出口规则也被移除，不影响其他用户。

用户添加、删除与出口变更使用相同的候选校验和事务回滚流程，需要已安装 Xray，并会重启服务。
分享链接包含对应用户的访问凭据，应视为秘密；不会包含上游出口凭据。

### 旧全局用户兼容性

新的节点内用户保存于 `.nodes[].users`。旧元数据中的顶层 `users` 和节点 `clients` 字段
继续保留但忽略，不会自动迁移、清洗或重新启用。需要访问的用户应在目标节点内重新添加并使用新链接。
仅替换脚本不会改变正在运行的 Xray 配置；下次重新生成并应用配置时，旧额外连接用户及其路由
不会被保留，其旧分享链接不再授权访问。

部署前请备份 `onevps-nodes.json` 和 `config.json`。恢复旧脚本并重新生成配置可能重新启用
旧全局用户，同时忽略新的节点内用户和出口覆盖；不要通过降级保留本版本的访问控制或出口设置。

## Realm 端口中转

选择菜单 `10`，再选择 `1`，即可安装 realm 并添加中转，无需先安装 Xray。
依次输入本地端口、目标 IP 或域名、目标端口，以及 `tcp`（默认）或 `both`（TCP+UDP）。
例如：将本地 `10443` 端口通过 TCP 转发到 `203.0.113.20:443`。
目标支持 IPv4、域名和不带方括号的 IPv6 地址；本地监听 `0.0.0.0`（IPv4）。

**安全提醒：** realm 不会额外提供认证或加密。仅开放必要端口，按需在防火墙限制来源地址，
并保留目标协议本身的安全保护。请手动放行主机防火墙和云安全组，脚本不会自动修改这些规则。
现有 Xray 分享链接不会自动改写；客户端接入中转时应保留目标的 TLS／Reality 服务名称。

子菜单支持查看规则及服务状态、删除规则、重启和独立卸载。删除最后一条规则会停止服务并取消开机启动。
规则启用失败时恢复旧配置，并尝试恢复原服务状态。本地监听检查成功不代表目标可达，
请通过客户端验证连接；故障日志使用 `journalctl -u onevps-realm` 查看。

安装使用官方 [realm v2.9.6 发布包](https://github.com/zhboner/realm/releases/tag/v2.9.6)，
按 GitHub 发布资产的 SHA-256 摘要校验，支持 amd64、arm64 和 armv7。
后续添加规则复用已安装版本，不自动升级。
依赖支持 `DynamicUser` 的 systemd（232+）、`tar` 及 `ss`；
Debian/Ubuntu 的 `ss` 来自 `iproute2`，RHEL 系来自 `iproute`。
服务使用动态非特权用户运行，仅授予绑定低端口所需的能力。

| 资源 | 位置 |
| --- | --- |
| 二进制 | `/usr/local/bin/onevps-realm` |
| 配置 | `/usr/local/etc/onevps-realm/config.json` |
| 管理标记 | `/usr/local/etc/onevps-realm/.onevps-managed` |
| 服务 | `/etc/systemd/system/onevps-realm.service` |

上述路径存在非本脚本管理的文件时拒绝覆盖。其他 realm 安装不会被修改，但可能占用相同端口。
菜单 `9` 仅卸载 Xray；卸载 realm 使用菜单 `10` → `5`，防火墙规则需自行清理。

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
Connection settings:
1) Change port
2) Reset default UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target

Users / outbound:
7) Manage node users
8) Set node outbound

Node status:
5) Enable/disable node

Danger zone:
6) Delete node

0) Back
```

Trojan 节点操作：

```text
Connection settings:
1) Reset default password
2) Change domain
3) Change WS path
4) Rebuild Caddy route

Users / outbound:
7) Manage node users
8) Set node outbound

Node status:
5) Enable/disable node

Danger zone:
6) Delete node

0) Back
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

## BBR 与 TCP 优化

菜单 `7` 启用 BBR，并写入 `/etc/sysctl.d/99-bbr.conf`。状态分别显示默认 qdisc 与网卡实际队列。
已有 fq 不变；只有单一默认 `pfifo_fast` root（handle 为 `0:` 且无 filters）才允许替换。
自定义、多队列、fq_codel 和未知布局会保留。BBR 已启用分支不会改变队列。

菜单 `8` 将可选 TCP 设置写入 `/etc/sysctl.d/99-onevps-tune.conf`：

- 将 TCP buffer 上限设为 `67108864`，校验后保留各自当前的最小值和初始值
- 读取失败、三元组非法或初始值超过目标上限时拒绝操作，不覆盖旧配置
- 启用 TCP Fast Open（需要应用配合）、MTU probing，并提高 backlog
- 设置临时端口范围为 `10000-65535`；共享 socket、backlog 和端口设置可能同时影响非 TCP 流量
- `tcp_notsent_lowat` 是未发送数据的就绪阈值，不是全部发送内存的硬上限

缓冲上限不是预分配，这些设置不保证普遍提速。配置文件存在不代表运行时已生效。
写入或 sysctl 加载失败会明确报告；加载失败可能已经部分生效，不执行原子回滚，不支持的键也报告为失败。

此选项不再创建 swap，也不再设置 swappiness、journald 限额、conntrack、空闲后慢启动或 FIN timeout。
不会删除现有 swap、fstab 或 journald 文件，也不会猜测系统默认值来重置历史运行参数。
重新应用仅更新 OneVPS 自己的调优文件。

OneVPS 不再添加默认 UDP/443 阻断或提供其开关。历史 `block_udp443` metadata 保留但忽略。
已安装 Xray 中的旧规则仅在重新生成配置并成功应用后消失；这不保证客户端、上游或链路支持 QUIC。
私网、BitTorrent 和节点/用户出站规则保持不变。应用前请确认设置适合服务器上的其他工作负载。

## 卸载

菜单 `9` 删除 Xray 二进制、配置、节点元数据、geodata 和日志目录。

BBR 设置、系统优化文件、swap、Caddy、Caddyfile 和自定义站点内容会被保留，避免删除可能由其他服务共享的主机状态。

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
bash -n onevps.sh tests/test_onevps.sh
shellcheck --severity=warning onevps.sh tests/test_onevps.sh
bash tests/test_onevps.sh
```

## 版本发布

正式版本包含 `onevps.sh` 和 `SHA256SUMS`。发布说明及兼容性相关变更记录在
[CHANGELOG.md](CHANGELOG.md) 中。

## 参与贡献

欢迎提交问题报告、兼容性结果、文档改进和范围明确的 pull request。提交前请阅读
[CONTRIBUTING.md](CONTRIBUTING.md)。请勿在公开 issue 中包含节点 URL、UUID、密码、私钥或未脱敏的服务器日志。

安全敏感问题必须遵循 [SECURITY.md](SECURITY.md)，不要使用公开 issue。

## 许可证

OneVPS 使用 [MIT License](LICENSE)。

## 免责声明

仅在获得授权的系统和网络中合法使用 OneVPS。运维者负责审阅脚本、遵守所在地法律与服务商条款，并保护生成的凭据。
