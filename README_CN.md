# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md)

OneVPS 是在 Linux VPS 上部署与管理 **sing-box v1.14.3** 节点的 Bash 工具。

> `main` 正在重写为 sing-box 实现，功能实施与验证仍在进行，不代表已经完成生产验证。
> 本文描述新实现的范围，不代表旧发行版的行为。
> 原 Xray 实现保留于本地 `archive/xray` 分支，该分支尚未推送。

## 功能范围

- **VLESS + TCP + REALITY + Vision**：独立部署，无需自备域名或证书；
  客户端链接使用 `xtls-rprx-vision` 与 `chrome` uTLS 指纹。
- **Hysteria 2 + 原生 ACME**：独立 UDP，自动 HTTP-01 证书管理，可选 salamander 混淆。
- **Snell**：原生 sing-box 服务端 v5、Surge v4 配置导出，每节点独立 PSK，支持 UDP over TCP。
- Reality/Hysteria 2 节点内用户、独立凭据与分享链接、节点出口及用户独立出口覆盖。
- 候选配置校验、服务管理、独立 Realm 中转、BBR 与可选 TCP 优化。

不提供流量统计、订阅、Web 面板、配置迁移或双内核运行。
本工具不替代主机加固、防火墙管理、监控或备份。

## 仅支持全新安装

新实现采用独立路径，元数据使用 **`schema_version: 1`**。不会导入或转换 Xray 或历史 sing-box 安装。
遇到旧配置或服务冲突时停止当前操作，不自动覆盖文件、删除旧安装，也不会自动停止其他服务来接管。
请先备份已有部署，再明确处理冲突；不要直接复用旧元数据。

环境要求：使用 systemd 的 Linux、root 权限、amd64/arm64/armv7，以及 apt/dnf/yum/zypper。
依赖包括 Bash、`curl`、`jq`、OpenSSL、有效 CA 证书包、`ss`（iproute2/iproute）、
`flock`（util-linux）、解压与 SHA-256 工具。
发行版及架构兼容性仍需运行验证。

### 获取脚本

安装与更新直接下载仓库 `main` 分支的当前文件，不依赖 GitHub Release、Release API、tag 或校验清单。
执行前先审阅源码。在受支持的 Linux 上准备 Bash、curl、CA 证书和 sudo 后，从可信且可写的目录运行：

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/0nevps/OneVPS/main/install.sh && sudo bash install.sh
```

命令会保存（或覆盖）当前目录下的 `install.sh`。必须在交互终端执行，**不要使用 `curl | bash`**。
没有 sudo 的 root 用户可将 `sudo bash` 换成 `bash`。
命令与下载的管理脚本依赖 GitHub/HTTPS 信任，不进行 Release 摘要或签名校验。
安装器下载 `main/onevps.sh` 时仅允许 HTTPS 重定向并忽略本地 curlrc，无需 token。
两次下载之间 `main` 可能变化，不保证不可变的发布快照。

#### 安装行为

安装器检查 Bash 语法、托管标记和版本字段基本格式后，原子安装到 `/usr/local/bin/onevps` 并启动。
拒绝非托管目标和符号链接；下载或验证失败保留原脚本。这些检查不等于发布者身份验证。
需要 root（可通过 sudo）、Linux/systemd 和 amd64/arm64/armv7。首次运行确认安装固定核心后，选择
Reality、Hysteria 2 或 Snell，并继续使用已有参数交互；已有托管安装跳过核心安装，不重置配置。
不自动启用 BBR、TCP 优化或 Realm；保留现有核心冲突保护与激活回滚。

```bash
sudo onevps                       # 再次管理，或继续首次安装
onevps --version                 # 无需 root，显示脚本版本和固定核心版本
sudo onevps update               # 当前 main，仅更新管理脚本
```

`install.sh` 与 `onevps update` 均不接受版本参数。更新直接下载同一份 `main` 原始脚本，
不获取执行另一个安装器，不升级核心、不修改节点、不重启服务；核心更新保留为明确的菜单操作。
核心固定为官方 **sing-box v1.14.3**，安装前校验归档 SHA-256。
脚本版本字段仅供显示，不代表已经发布，也不能唯一标识 `main` 提交。

开发时可在临时环境审阅指定仓库提交后运行 `sudo bash onevps.sh`，该方式不会安装 `onevps` 命令。
Release 发布功能独立保留，不作为安装前提；流程见 [CONTRIBUTING.md](CONTRIBUTING.md#releases)。
[CHANGELOG.md](CHANGELOG.md) 保留历史发布记录。

## Snell

菜单 **12** 添加原生 sing-box Snell 节点，无需独立 snell-server、域名或证书。
服务端使用 `version: 5`，导出的 Surge `[Proxy]` 配置明确使用 `version=4`。
这是有意的版本配对：sing-box 不实现 v5 QUIC Proxy Mode。TCP 和 UDP over TCP 共用选定的 TCP
监听端口（默认 8443），云安全组只需开放该 TCP 端口。不要将 Surge 配置改为 v5。

每个节点使用随机生成的 32 位十六进制 PSK。节点管理支持改端口、轮换 PSK、启停、删除及节点出口。
Snell 不支持节点内多用户及用户级出口覆盖；独立凭据使用不同节点和端口。
导出使用稳定生成的节点 tag 作为 Surge 策略名称，不使用自由输入的显示名称。导出配置包含 PSK，需妥善保管。
轮换成功应用后，旧客户端配置失效，需重新导出。

Snell 复用现有配置校验、监听检查、回滚和私网阻断。监听就绪不等于客户端握手通过。
删除和改端口后保留防火墙放行规则。首期不提供订阅、Snell 出站导入、v6、可选混淆设置或明文模式。
旧版 OneVPS 会拒绝包含 Snell 节点的元数据；降级前需用当前版本删除 Snell 节点。

Snell 不提供前向保密或专门的重放保护。请保护随机 PSK，不将其安全属性视为与 TLS 等同。
真实 Surge 互通与 Linux 主机级部署仍需验收，同内核测试不能替代这些验证。

## Hysteria 2 与原生 ACME

菜单 **11** 添加 Hysteria 2 节点，要求固定核心包含 `with_quic`、`with_acme`。
已有 OneVPS 安装请先通过菜单 **1** 更新服务单元，允许 ACME 持久目录写入。
不依赖 Caddy 或外部 ACME 客户端。首期要求域名 A 记录直接指向本 VPS，并具备 `getent`、`ss`，
公网 TCP/80 必须在申请及续期时可达。若存在 AAAA 记录，也需指向可达的本机地址；
DNS 预检仅核对 IPv4，不证明公网可达。其他服务占用 TCP/80 时停止操作，不自动接管。

使用 Let’s Encrypt 签发，关闭 TLS-ALPN-01，避免占用 Reality 的 TCP/443。
公开签发会向 CA 和证书透明度日志披露域名，创建菜单会先确认。
Hysteria 2 独立监听 IPv4 UDP；UDP/443 可能已被 HTTP/3 占用，应选择其他端口，不停止原服务。
云安全组需开放选定 UDP 端口。支持可选 salamander 混淆，分享链接使用 `hysteria2://`，
严格验证 TLS，不添加 `insecure=1`。支持节点内多用户和分层出口；暂不支持 HY2 出站链接导入。

ACME 账户、证书和私钥保存在 `/var/lib/onevps-acme`，仅服务用户可写，不随普通配置事务回滚。
相同域名的启用节点复用 provider，必须配置相同 ACME 邮箱。续期和证书缓存更新由运行中的核心管理。
当域名不再被任何启用节点引用时，配置不再包含其 provider，续期暂停；重新启用后恢复管理。
停止或卸载核心同样停止续期。删除节点与卸载均保留 ACME 数据供人工备份及清理，不递归删除私钥。
失败、改端口和删除后保留所有防火墙放行规则，包括 Reality TCP、TCP/80 与 HY2 UDP，
避免误删共享或既有规则，需人工审查。防火墙放行失败会中止启用，不再报告节点可用。

应用含启用 HY2 节点的配置后，脚本启动短命 loopback 客户端，每个节点等待约 90 秒，
验证可信 TLS/QUIC，并通过默认用户出口请求 `https://www.example.com/`。
失败则恢复配置与原服务状态，但不撤销 CA 签发或防火墙放行。探测依赖出口正常，
不证明公网 UDP 可达或所有用户路由正确。回滚后新签证书可能仍保留在 ACME 存储中。
配置 `check` 本身不会申请证书。首期不提供 DNS-01、自签名部署、端口跳跃和修改域名菜单。

本地 v1.14.3 已验证 ACME 配置检查，以及 HY2 TCP/UDP、多用户路由、错误密码/TLS 名称拒绝、
salamander、私网阻断和删除用户拒绝。运行测试将 ACME 替换为显式信任的临时 localhost 证书，
不访问公共 CA。真实公网签发、续期、Linux 服务权限与防火墙、跨客户端互通仍未验证，
生产验收前应在授权临时主机上使用 ACME staging 验证。

## 用户、分层出口与分享链接

用户仅属于一个节点，不存在全局账号池。新增 Reality 用户使用独立 UUID，Hysteria 2 用户使用独立密码。
同一节点内用户名及凭据必须唯一。保留的默认客户端通过节点重置操作管理，不通过用户菜单删除。
删除新增用户并成功应用后，其访问权限失效，独立出口覆盖也随之移除。

域名目标在私网安全规则匹配前先由本机解析，包括使用上游代理的流量，防止域名形式的私网目标绕过阻断。

出口优先级为 **安全阻断 → 用户独立出口 → 节点出口 → 直连**：

- **指定用户**：仅修改当前节点选中的身份，包括默认客户端；恢复默认会删除覆盖，重新继承节点出口。
- **所有用户**：设置节点出口，并清除该节点全部用户覆盖；新增用户继承节点出口。
  恢复默认会清除两层设置，回到直连。
- 显式**直连**可覆盖节点代理，但不能绕过私网地址或 BitTorrent 安全阻断。
  上游失败不自动回退直连；操作不影响其他节点。

每次粘贴一条出口链接；输入可见，凭据可能显示在屏幕上。

| 链接 | 接受范围 |
| --- | --- |
| `ss://` | SIP002；仅 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305` |
| `socks5://` | 主机与端口，可选百分号编码的用户名及密码 |
| `vless://` | TCP + REALITY；TCP、WebSocket 或 gRPC + TLS；gRPC 仅 `mode=gun` |

Shadowsocks 接受 Base64URL 或百分号编码的明文 userinfo，不支持 SS2022、插件或整条链接 Base64。
VLESS 拒绝 `spx`、gRPC `mode=multi`、XHTTP、不安全 TLS 选项、未知或重复参数及与传输不匹配的字段。
Vision 仅限 TCP；WS 路径按字面处理，不作为 early-data 配置。
SOCKS5 不加密流量或凭据，请使用可信或受保护的链路；UDP 能力取决于上游。

分享链接包含客户端访问凭据，不包含上游代理凭据。请保护链接、元数据、运行配置及备份。
变更须通过真实内核 `check` 才能启用，应用时可能重启原本停止的服务。
启用失败需要回滚元数据与配置，并尝试恢复原服务状态；这不保证文件替换过程具有断电安全性。
安装、配置变更与卸载共用非阻塞进程锁；存在其他操作时需待其完成后重试。
提交前检查服务 PID 持续稳定，且所有启用节点的 TCP/UDP 监听均属于该进程；存在 HY2 时再执行客户端探测。
监听就绪等待约 10 秒；含启用 HY2 节点时约 90 秒，以便初始化证书。这不等同于 Reality 或 Snell 端到端握手验证。
公网 IPv4 查询失败不会输出无效 Reality 链接或 Snell 配置，也不阻止节点管理。
可用 `sudo env PUBIP=YOUR_SERVER_IPV4 bash onevps.sh` 显式指定服务器地址后重试。

## 文件与运维

| 资源 | 位置 |
| --- | --- |
| 固定版本核心 | `/usr/local/bin/onevps-sing-box` |
| 运行配置 | `/usr/local/etc/onevps/config.json` |
| 节点元数据与秘密 | `/usr/local/etc/onevps/onevps-nodes.json`（`schema_version: 1`） |
| 服务单元 | `/etc/systemd/system/onevps-sing-box.service` |

```bash
/usr/local/bin/onevps-sing-box version
/usr/local/bin/onevps-sing-box check -c /usr/local/etc/onevps/config.json
systemctl status onevps-sing-box.service
systemctl restart onevps-sing-box.service
journalctl -u onevps-sing-box.service -f
```

生成配置通过校验后才启用。核心使用非特权用户运行，并保留绑定低端口的能力；凭据文件需限制权限。
核心与 Realm 分开卸载；外部服务与主机级调优设置予以保留。

## Realm、BBR 与 TCP

**Realm** 独立于 sing-box，可从 IPv4 监听端口将 TCP 或 TCP+UDP 转发至 IPv4、IPv6 或域名目标，
但不会增加认证或加密。仅在主机防火墙及云安全组开放必要端口，中转配置不会代为放行。
客户端链接不会自动改写；接入中转时保留 TLS/REALITY 服务名称。

Realm 使用官方固定 `v2.9.6` 归档并验证 SHA-256，依赖支持 `DynamicUser` 的 systemd、`tar` 与 `ss`。
路径为 `/usr/local/bin/onevps-realm`、`/usr/local/etc/onevps-realm/config.json`，
服务为 `onevps-realm.service`；不会覆盖非本工具管理的文件。
通过独立子菜单管理及卸载。本地端口监听成功不代表目标可达。

**BBR** 写入 `/etc/sysctl.d/99-bbr.conf`。默认 qdisc 不等同于网卡实际队列；
自定义或多队列布局保留，只有识别出的单一默认 `pfifo_fast` root 才允许替换。

**TCP 优化** 写入 `/etc/sysctl.d/99-onevps-tune.conf`，校验并保留当前最小值及初始值后提高 TCP buffer 上限，
并调整 Fast Open、MTU probing、backlog 与临时端口。共享 socket 设置可能影响非 TCP 流量。
不创建 swap，不调节 journald/conntrack，不添加默认 UDP/443 阻断。
不保证提速；sysctl 加载失败可能已经部分生效，不提供原子回滚。

## 验证与贡献

语法、ShellCheck、单元、Markdown 及 `tests/test_singbox.sh` 真实内核检查见
[CONTRIBUTING.md](CONTRIBUTING.md)。该脚本调用 `tests/runtime_singbox.py`，仅依赖 Python 3 标准库；
运行验证使用 loopback 短命进程，不操作宿主服务。

macOS arm64 上使用 **sing-box v1.14.3** 已通过 11 种出站配置检查，以及本地运行验证：
Hysteria 2 的 TCP/UDP 转发、错误密码拒绝、基于 `auth_user` 的分层路由、私网 CIDR 拒绝，
和以本地 TLS 1.3 服务为目标的 VLESS REALITY Vision 实际握手及 TCP 转发。
这些结果仅覆盖同内核本地测试，不代表生产验证、其他客户端兼容性已通过。
单独通过配置 `check` 也不证明连通性。跨客户端互通和主机级失败路径仍需在临时主机验证，记录环境与结果。

报告问题时附脱敏环境信息与准确版本。漏洞请按 [SECURITY.md](SECURITY.md) 私密报告，
不要公开凭据或原始生产日志。

## 许可证与责任

[MIT License](LICENSE)。仅在获得授权的系统及网络使用，遵守适用法律与服务商条款，
执行前审阅下载内容和主机变更。
