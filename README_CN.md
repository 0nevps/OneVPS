# OneVPS

[English](README.md)

VPS 一键搭建 Xray 节点脚本，支持两种协议：

- **VLESS + TCP + REALITY + XTLS Vision + uTLS**（主线）——无需域名、无需证书。
- **Trojan + WebSocket（Caddy 后端）**——复用 Caddy 的 `:443` 与证书，与 Caddy 已反代的其它服务共存。

基于 [Xray-core](https://github.com/XTLS/Xray-core)。Reality 路线无需域名/证书；Trojan 路线需要 Caddy（缺失时自动安装）。

---

## 特性

- **Xray-core 官方安装器**：通过 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装/更新核心与 geodata
- **VLESS + TCP + REALITY**：直连 VPS，Reality 借用目标站 TLS 握手特征
- **XTLS Vision**：服务端用户固定 `flow: xtls-rprx-vision`
- **uTLS**：分享链接固定 `fp=chrome`，兼容主流客户端
- **Trojan + WS（Caddy 后端）**：Xray 入站仅监听 loopback，Caddy 在 `:443` 终结 TLS，并把独立子域下的隐藏 WS 路径反代到本地入站，与其它 Caddy 站点共存。缺失时自动安装 Caddy。
- **安全默认值**：随机 UUID、X25519 密钥、16 位 shortId，阻断私网地址、BT 协议和 UDP/443
- **服务加固**：systemd 使用 `nobody` 运行，仅保留绑定低端口所需能力
- **运维能力**：节点管理、分享链接、BBR、基础系统优化

> 旧版 sing-box 节点不会自动迁移。新版脚本使用 `/usr/local/etc/xray/` 作为配置目录。

---

## 快速开始

一键运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh)
```

或下载后本地运行：

```bash
sudo bash onevps.sh
```

首次使用：先运行 `1` 安装/更新 Xray-core，再运行 `2` 添加 Reality 节点，或 `3` 添加 Trojan + WS 节点。

---

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

---

## 节点配置

| 项目 | 默认值 |
|------|--------|
| 协议 | VLESS |
| 传输 | TCP |
| 传输安全 | REALITY |
| 流控 | `xtls-rprx-vision` |
| uTLS 指纹 | `chrome` |
| 加密 | `none` |
| 默认端口 | `443`，被占用时改随机端口 |

分享链接格式：

```text
vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=TARGET&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&type=tcp#NAME
```

---

## Reality 目标站

脚本内置候选：

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

目标站建议满足：

- 支持 TLS 1.3 和 H2
- SNI 稳定，证书 SAN 覆盖所填域名
- 尽量选择与你 VPS 网络位置延迟较低的站点

添加或修改节点时，默认会对内置候选执行多轮 `xray tls ping`，按成功率和平均耗时自动选择目标站；也可以手动指定候选或自定义域名。探测全部失败时会回退到第一个候选，但建议换一个更稳定的目标站。

---

## Trojan + WS（Caddy 后端）

菜单 `3` 添加运行在 Caddy 后端的 Trojan 节点，与 Caddy 已服务的其它内容共用 `:443`。

工作方式：

- Xray Trojan 入站**仅监听 `127.0.0.1`**，**不做 TLS**（`network: ws`）。
- Caddy 在 `:443` 终结 TLS，为**独立子域**自动签发证书，并把**隐藏 WS 路径**反代到本地入站。其它 Caddy 站点/路径不受影响。
- 只有**密 WS 路径**会反代到 Xray（由 Caddy `reverse_proxy` 完成 WebSocket 升级）。其余所有路径一律返回 **HTTP 403 + 403 页面**（`/var/lib/onevps/sites/<域名>/index.html`），子域其余部分看起来像受限站点，而非死代理。随机路径本身即是秘密。可随时把该 `index.html` 换成自己的内容，脚本不会覆盖。
- Trojan 节点不修改防火墙——仅 Caddy 对外。

要求：

- 子域有 `A`/`AAAA` 记录指向本机（Caddy 才能签证书）。
- `80` 与 `443` 端口可达（ACME 与流量）。
- 已安装 Caddy——缺失时脚本自动安装（官方 apt/dnf/yum 源，或静态二进制 + systemd 单元兜底），并创建默认 Caddyfile。

脚本会向 Caddyfile 追加带标记的站点块，校验后 reload Caddy。删除节点时移除该块并再次 reload。

分享链接格式：

```text
trojan://PASSWORD@SUBDOMAIN:443?security=tls&sni=SUBDOMAIN&type=ws&host=SUBDOMAIN&path=PATH#NAME
```

---

## 节点管理

菜单 `4` 的操作随节点类型变化。

Reality 节点：

```text
1) 修改端口
2) 重置 UUID
3) 轮换 Reality 密钥和 shortId
4) 修改 Reality 目标站
5) 启用/停用
6) 删除节点
```

Trojan 节点：

```text
1) 重置密码
2) 修改域名
3) 修改 WS 路径
4) 重建 Caddy 路由
5) 启用/停用
6) 删除节点
```

`重建 Caddy 路由` 用节点已存字段重新生成 Caddy 块，不改密码/路径/端口——脚本更新后用它把旧节点刷成当前 Caddy 模板。

轮换 Reality 密钥/shortId，或重置 Trojan 密码/路径后，旧客户端链接会失效，需要重新导入菜单 `5` 输出的新链接。

---

## 文件位置

| 路径 | 用途 |
|------|------|
| `/usr/local/bin/xray` | Xray 核心二进制 |
| `/usr/local/etc/xray/config.json` | Xray 运行配置，由脚本生成 |
| `/usr/local/etc/xray/onevps-nodes.json` | 节点元数据 |
| `/usr/local/share/xray/` | geoip/geosite 数据 |
| `/etc/systemd/system/xray.service` | systemd 服务 |
| `/var/log/xray/` | Xray 日志目录 |
| `/var/lib/onevps/sites/<域名>/` | Trojan 子域的 403 伪装页（可编辑） |

手动管理服务：

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -f
```

配置检查：

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

---

## 环境要求

- Linux + systemd
- root 权限
- 架构：amd64 / arm64 / armv7
- 包管理器：apt / dnf / yum / zypper
- 依赖自动安装：`curl` `jq` `openssl`
- 仅在添加 Trojan 节点时自动安装 Caddy

---

## BBR 与系统优化

菜单 `7` 可启用 BBR，写入 `/etc/sysctl.d/99-bbr.conf`。

菜单 `8` 应用偏保守的长期稳定型优化：

- 提高 TCP buffer 上限，但不抬高每个 socket 的默认 buffer
- 开启 TFO、MTU probing，并提高 backlog
- 将临时端口范围设为 `10000-65535`
- 可创建小 swap，限制 journald 磁盘占用
- 可切换 Xray 出站 UDP/443 阻断；默认开启以减少 QUIC/HTTP3 带来的路由和稳定性问题

---

## 卸载

菜单 `9` 会删除 Xray 二进制、配置、节点元数据、geodata 与日志目录。

BBR、系统优化配置、swap 文件，以及 Caddy（含 Caddyfile）会保留。

---

## 免责声明

仅供学习与合法网络调试用途。请遵守所在地法律法规及 VPS 服务商条款。
