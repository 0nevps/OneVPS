# OneVPS

VPS 一键搭建代理节点脚本，基于 [sing-box](https://github.com/SagerNet/sing-box)。

支持协议：

- **VLESS + Reality** — 直连，无需域名/证书，伪装真站 TLS 指纹
- **VLESS + WebSocket + CF CDN** — 套 Cloudflare 橙云代理，隐藏真实 IP
- **Hysteria2** — QUIC/UDP 高速直连
- **SOCKS5** — 带认证的 SOCKS5 代理入站

两个可选增强：

- 🟠 **Cloudflare CDN** — VLESS 节点可套 CF（自动切换为 WS 传输）
- 🧦 **SOCKS5 落地** — 给任意节点挂带认证的 SOCKS5 出口，VPS 当前置

---

## 快速开始

```bash
sudo bash onevps.sh
```

脚本启动先做环境检测（root / 架构 / 包管理器 / systemd），通过后进入菜单。

首次使用：先跑 `1` 安装 sing-box，再 `2`/`3`/`4` 添加节点。

---

## 菜单

```
1) 安装 / 更新 sing-box
2) 添加节点 — VLESS (Reality / WS+CF)
3) 添加节点 — Hysteria2
4) 添加节点 — SOCKS5
5) 管理节点
6) 查看全部分享链接
7) 重启服务
8) 卸载
0) 退出
```

---

## 协议与模式

| 场景 | 协议 | 传输 | 域名 | 证书 |
|------|------|------|------|------|
| VLESS 不套 CF | VLESS + Reality | TCP 直连 | 不需要 | 不需要（Reality 伪装） |
| VLESS 套 CF | VLESS + WS | WebSocket 经 CF | 必须 | 自签（CF 终结 TLS） |
| Hysteria2 | Hysteria2 | QUIC/UDP | 可选 | ACME 或 自签 |
| SOCKS5 | SOCKS5 | TCP | 不需要 | 不需要 |

### VLESS + Reality

- 直连 VPS，无需域名或证书
- 伪装目标站需支持 TLS 1.3 + H2（预设：microsoft.com、apple.com 等）
- 客户端使用 `flow: xtls-rprx-vision`
- 分享链接格式：`vless://...?security=reality&fp=chrome&pbk=...&sid=...`

### VLESS + WS + CF CDN

- 域名在 Cloudflare 托管，A 记录指向 VPS，橙云开启
- VPS 侧自签证书 + CF 面板设 **完全(Full)**
- CF 免费版回源 HTTPS 端口：`443 2053 2083 2087 2096 8443`（脚本强制校验）
- 分享链接格式：`vless://...?security=tls&type=ws&host=...&path=...`

> **为什么套 CF 用自签？** CF 橙云会拦截 ACME 的 HTTP-01 验证，签不出真证书。
> 回源用自签 + CF "完全(Full)" 模式，VPS↔CF 之间仍加密。

### Hysteria2

- QUIC/UDP 直连，CF 不支持代理 UDP
- 有域名可用 ACME 真证书；无域名用自签（客户端需开 `insecure`）

### SOCKS5

- 带用户名/密码认证的 SOCKS5 代理
- 无需域名或证书，最轻量的节点类型
- 可选挂 SOCKS5 落地出口（套娃：客户端 → VPS SOCKS5 入站 → 远端 SOCKS5 出站）
- 分享链接格式：`socks5://user:pass@ip:port#name`

---

## SOCKS5 落地

添加节点时或在「管理节点」里可挂 SOCKS5 出口：

```
SOCKS5 服务器地址: residential.example.com
SOCKS5 端口: 1080
用户名: user
密码: ******
```

挂上后该节点 **全部流量**（含 DNS）从 SOCKS5 出口落地，VPS 仅作前置中转。

> ⚠️ 无故障回落：SOCKS5 出口挂掉时该节点直接不可用。

---

## 节点管理

菜单 `5` 选择节点后：

```
1) 切换 SOCKS5 落地(改/加/删)
2) 修改端口
3) 重置 UUID / 密码
4) 启用/停用
5) 删除节点
6) 修改 Reality 伪装站 (仅 Reality 节点)
```

---

## 文件位置

| 路径 | 用途 |
|------|------|
| `/usr/local/bin/sing-box` | 内核二进制 |
| `/etc/sing-box/nodes.json` | 节点元数据（唯一真相源） |
| `/etc/sing-box/config.json` | sing-box 运行配置（由 nodes.json 自动生成） |
| `/etc/sing-box/certs/` | 自签证书（Reality 不使用） |
| `/etc/systemd/system/sing-box.service` | systemd 服务 |

手动管理服务：

```bash
systemctl status sing-box
systemctl restart sing-box
journalctl -u sing-box -f
```

---

## 环境要求

- Linux + **systemd**
- root 权限
- 架构：amd64 / arm64 / armv7
- 包管理器：apt / dnf / yum / apk
- 依赖自动安装：`curl` `jq` `openssl` `tar`

---

## 卸载

菜单 `8`，删除二进制、配置、所有节点与证书。

---

## 免责声明

仅供学习与合法网络调试用途。请遵守所在地法律法规及 VPS 服务商条款。
