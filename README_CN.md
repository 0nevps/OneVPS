# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[English](README.md)

OneVPS 以 [`onevps-singbox.sh`](onevps-singbox.sh) 为主要使用和维护入口，在 Linux VPS 上部署和管理
sing-box 节点。脚本使用 Bash 启动 Python 3 程序，集中管理核心安装、节点、用户、出站、Caddy 证书、
Realm 中转和服务诊断。原有 [`onevps.sh`](onevps.sh)（Xray）仍在仓库中，但不与 sing-box 节点互通。

> **运行前请审阅脚本。** 它以 root 权限安装软件、修改 systemd 服务、Caddy 配置与主机防火墙，
> 可选修改全局内核参数。请先在可回滚的 VPS 上试用；分享链接和配置文件包含访问凭据。

## 快速开始

要求 Linux + systemd、root 权限、Python 3.8+；首次安装会尝试通过 apt、dnf、yum 或 zypper
补齐 Python 3，安装核心时也会检查 `curl`、`openssl`、`ss`。从 `main` 下载脚本到**普通文件**，审阅后运行：

```bash
curl -fLO https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps-singbox.sh
less onevps-singbox.sh
sudo bash onevps-singbox.sh
```

该地址跟随 `main`，不是固定版本。首次进入菜单先选 `1` 安装或更新 sing-box（要求 >= 1.14.0），
再选 `2` 创建节点并获取链接。根据节点类型提前准备 DNS、开放云安全组端口，并在其他网络上用客户端验证连接。
**不要使用 `bash <(curl ...)`**：脚本安装证书同步定时器和执行自身更新时需要从已保存的脚本文件读取内容。

目前 Release 工作流仍只发布 Xray 的 `onevps.sh` 和 `SHA256SUMS`；Release 校验文件**不适用于**上面的
sing-box `main` 分支下载。CI 目前也未运行 sing-box 离线自测，维护者需要单独执行下方的检查。

## 选择节点

在主菜单选 `2`，按需添加节点；`2 → 8` 管理已有节点及用户，`2 → 9` 查看所有分享链接。

| `2` 子菜单 | 节点 | 网络与前置条件 |
| --- | --- | --- |
| `1` | VLESS + REALITY + Vision | TCP；无需域名或证书，默认尝试 443 |
| `2` | Trojan + WS + Caddy | TCP 80/443；域名指向 VPS，Caddy 终结 TLS |
| `3` | VMess AEAD + WS + Caddy | TCP 80/443；域名指向 VPS，Caddy 终结 TLS |
| `4` | Hysteria2 + TLS | UDP；需要域名、Caddy 证书，默认端口 24443 |
| `5` | Snell v5（Surge） | TCP；sing-box 不实现 Snell v5 QUIC Proxy Mode |
| `6` | Snell v6（Surge） | TCP；需要兼容的 Surge 客户端 |
| `7` | Shadowsocks 2022（Surge） | TCP + UDP；使用 `2022-blake3-aes-128-gcm` |

WS 入站仅监听本机 `127.0.0.1`，由 Caddy 转发隐藏路径；无匹配路径的站点请求返回可定制的 403 页面。
Hysteria2 在 UDP 端口监听，Caddy 负责申请证书，定时器将证书同步给 sing-box。
脚本会尝试为节点开放活动的 `ufw`/`firewalld` 规则，但**云厂商安全组仍需手动放行**；
请根据实际 DNS、监听协议和端口配置入站规则。BBR 和 TCP 调优并不等同于 UDP/QUIC 调优。

Snell v5/v6 的单用户输出为 Surge `[Proxy]` 配置；Snell 多用户的 `userkey` 没有已文档化的
Surge 策略语法，脚本改为输出 sing-box 客户端出站 JSON，不会伪造 Surge 配置。
Shadowsocks 2022 输出 `ss://` 和 Surge 配置。多用户模式可能改变默认用户的链接，添加前会提示确认。

## 日常维护

```text
1) Install / update sing-box (stable >=1.14)
2) Nodes / users / outbound / share links
3) Caddy TLS certificate management
4) Realm relay
5) Service / BBR / TCP tuning
6) Update script
7) Diagnostics
8) VPS-local acceptance checks
9) Uninstall managed sing-box
0) Exit
```

- **节点与用户：** `2 → 8` 选定节点后，`1` 改端口、`2` 重置默认凭据、`3` 管理用户、
  `4` 设置出站、`5` 启停、`6` 删除、`7` 显示链接；REALITY 节点还有密钥/目标站操作，
  WS 节点还有域名/路径/Caddy 路由操作。重置凭据后旧链接立即失效。
- **出站：** 可对全节点用户或指定用户选择继承、显式直连或粘贴一条上游链接；支持
  `ss://`、`socks5://`、`vless://`、`vmess://`（v2 Base64 JSON）和 `snell://` 的脚本实现子集。
  全员设置会清除个人覆盖；安全阻断规则优先于用户出站、节点出站及默认直连。
  上游失败不会自动回退直连。粘贴链接时输入和持久化配置可能包含秘密。
- **证书：** `3` 可申请证书、查看到期时间、手动同步和查看 Caddy/定时器状态。
  DNS 域名需指向 VPS，TCP 80/443 可达；同步定时器每 5 分钟运行一次。不要覆盖已有站点的域名。
- **中转与网络：** `4` 管理独立的 Realm TCP 或 TCP+UDP 中转；Realm 不提供额外认证或加密。
  `5` 重启并检查服务、查看日志，或选择性开启全局 BBR/TCP 调优。
- **脚本更新：** `6` 从仓库 `main` 下载新脚本，检查 Bash 语法、显示 SHA-256 并请求确认后替换
  当前保存的文件和已安装的维护脚本；重新启动菜单后才使用新版本。此操作不等于更新 sing-box 核心。
- **卸载：** `9` 移除受管节点、配置、服务及证书同步定时器；可选卸载核心包。
  Caddy、Realm 和 sysctl 设置保留，不会替你收回云安全组规则。

节点配置通过 sing-box `check` 后才写入；应用时重启并检查服务和监听端口，检测到失败会尝试恢复
原有元数据、配置、Caddy 路由及服务状态。仍请在变更前自行备份，尤其不要把回滚机制视为断电保护。

## 检查与排障

在 VPS 上运行以下命令；`--check` 和 `--acceptance` 需要 root，可能读取本机配置、服务、
监听端口和证书，不是无副作用的纯解析检查：

```bash
sudo bash onevps-singbox.sh --version
sudo bash onevps-singbox.sh --check
sudo bash onevps-singbox.sh --acceptance
systemctl status onevps-singbox.service
journalctl -u onevps-singbox.service -n 50 --no-pager
```

`--check` 查看核心、服务、配置与预期监听状态。`--acceptance` 额外检查 Caddy 站点、证书和
Realm（如已配置），失败时返回非零状态。**两者都无法证明公网 DNS、云安全组、外部客户端
握手、UDP/QUIC 流量或实际 ACME 续期正常**；请从独立网络实测。
如 TLS 尚未签发，在确认 DNS 与 TCP 80/443 后到菜单 `3` 重试证书同步，检查 Caddy 状态。

| 位置 | 用途 |
| --- | --- |
| `/etc/onevps-singbox/nodes.json` | 节点元数据与凭据 |
| `/etc/onevps-singbox/config.json` | 生成的 sing-box 配置 |
| `/etc/onevps-singbox/certs/` | 同步给 sing-box 的证书 |
| `/etc/caddy/onevps-singbox.caddy` | 受管域名的 Caddy 配置片段 |
| `/var/lib/onevps/sites/<域名>/index.html` | 可定制的 403 页面 |
| `/etc/systemd/system/onevps-singbox.service` | sing-box 服务 |
| `/etc/systemd/system/onevps-singbox-certs.timer` | 证书同步定时器 |
| `/usr/local/sbin/onevps-singbox` | 定时器使用的维护脚本副本 |

保管好包含凭据的文件、备份和分享链接，不要把它们或未脱敏日志贴到公开 issue。

## 维护与测试

修改脚本或文档时优先以 [`onevps-singbox.sh`](onevps-singbox.sh) 的实际行为为准，同步更新
中英文 README，并在本地运行离线测试：

```bash
bash -n onevps-singbox.sh
bash onevps-singbox.sh --self-test
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

`--self-test` 在 Linux 上不需要 root 或公网，测试配置生成、链接、回滚等逻辑；部分测试需要本地
`openssl`，并假设 Linux 用户组及架构。
它不能替代在一次性 VPS 上安装 sing-box >= 1.14.0 后的实际握手、Caddy 证书和跨发行版测试。
现有 CI 和发布流程目前针对 Xray 脚本；维护 sing-box 时请单独执行上述检查并记录实机验证结果。

## Xray 旧版脚本

[`onevps.sh`](onevps.sh) 使用 Xray-core，有独立的服务 `xray.service` 和目录
`/usr/local/etc/xray/`。它不是本文菜单/参数/路径的适用对象，也不会自动导入、迁移或清理
`onevps-singbox.sh` 的节点；不要将两套脚本当作同一套配置管理器使用。
现有 Release 仅包含 Xray 脚本与配套校验文件，Xray 维护和测试细节见
[贡献指南](CONTRIBUTING.md)及[变更记录](CHANGELOG.md)。

疑似安全漏洞请按[安全策略](SECURITY.md)私密报告。仅在获得授权的系统和网络中合法使用；
运维者负责审阅脚本、遵守所在地法律与服务商条款，并保护凭据。本项目使用 [MIT 许可证](LICENSE)。
