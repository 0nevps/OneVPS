# OneVPS

[English](README.md)

VPS 一键搭建代理节点脚本，基于 [sing-box](https://github.com/SagerNet/sing-box)。

支持协议：

- **VLESS + Reality** — 直连，无需域名/证书，伪装真站 TLS 指纹
- **VLESS + WebSocket + CF CDN** — 套 Cloudflare 橙云代理，隐藏真实 IP
- **SOCKS5** — 带认证的 SOCKS5 代理入站

两个可选增强：

- 🟠 **Cloudflare CDN** — VLESS 节点可套 CF（自动切换为 WS 传输）
- 🧦 **SOCKS5 落地** — 给任意节点挂带认证的 SOCKS5 出口，VPS 当前置
- 🚀 **BBR 加速** — 一键开启内核 BBR TCP 拥塞控制，提升吞吐

---

## 快速开始

一键运行（远程拉取）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh)
```

或下载后本地运行：

```bash
sudo bash onevps.sh
```

脚本启动先做环境检测（root / 架构 / 包管理器 / systemd），通过后进入菜单。

首次使用：先跑 `1` 安装 sing-box，再 `2`/`3` 添加节点。

---

## 菜单

```
1) 安装 / 更新 sing-box
2) 添加节点 — VLESS (Reality / WS+CF)
3) 添加节点 — SOCKS5
4) 管理节点
5) 查看全部分享链接
6) 重启服务
7) BBR 加速
8) 系统优化
9) 卸载
0) 退出
```

---

## 协议与模式

| 场景 | 协议 | 传输 | 域名 | 证书 |
|------|------|------|------|------|
| VLESS 不套 CF | VLESS + Reality | TCP 直连 | 不需要 | 不需要（Reality 伪装） |
| VLESS 套 CF | VLESS + WS | WebSocket 经 CF | 必须 | 自签（CF 终结 TLS） |
| SOCKS5 | SOCKS5 | TCP | 不需要 | 不需要 |

### VLESS + Reality

- 直连 VPS，无需域名或证书
- 伪装目标站需支持 TLS 1.3 + H2（预设：microsoft.com、apple.com 等）
- 客户端使用 `flow: xtls-rprx-vision`
- 分享链接格式：`vless://...?security=reality&fp=chrome&pbk=...&sid=...`

### VLESS + WS + CF CDN

- 分享链接格式：`vless://...?security=tls&type=ws&host=...&path=...`

#### Cloudflare 配置步骤

1. **域名托管到 CF** — 域名的 NS 记录指向 Cloudflare（在注册商处修改）
2. **添加 DNS 记录** — CF 面板 → DNS → 添加 A 记录：
   - 名称：`你的域名`（如 `proxy.example.com`）
   - 内容：`VPS 真实 IP`
   - 代理状态：**已代理**（橙云 ☁️ 开启）
3. **SSL/TLS 加密模式** — CF 面板 → SSL/TLS → 概述 → 选 **完全(Full)**
   - ⚠️ 不要选「完全(严格)」— 本脚本用自签证书，严格模式会拒绝
   - ⚠️ 不要选「灵活」— 灵活模式回源走明文 HTTP，不安全
4. **WebSocket** — CF 默认已启用，无需额外设置
5. **回源端口** — CF 免费版仅代理以下 HTTPS 端口，脚本会强制校验：
   ```
   443  2053  2083  2087  2096  8443
   ```

#### 注意事项

- **生效时间**：DNS 记录改为「已代理」后，通常几分钟生效，偶尔需等数小时
- **真实 IP 泄露**：开启橙云前确保没有其他 DNS 记录（如 MX、未代理的子域名）暴露 VPS IP
- **CF 免费版限制**：无 WebSocket 连接数硬性限制，但高流量可能触发 CF 安全规则（如 Under Attack 模式、Rate Limiting）
- **客户端 SNI/Host**：必须填域名（非 IP），脚本生成的分享链接已自动处理

> **为什么套 CF 用自签？** CF 橙云会拦截 ACME 的 HTTP-01 验证，签不出真证书。
> 回源用自签 + CF "完全(Full)" 模式，VPS↔CF 之间仍加密。

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

## BBR 加速

菜单 `8` 一键启用 Google BBR TCP 拥塞控制算法（需内核 ≥ 4.9）。

启用后写入 `/etc/sysctl.d/99-bbr.conf`，设置 `fq` 队列调度 + `bbr` 拥塞控制，重启不丢失。

状态栏会显示当前 TCP 拥塞控制算法（如 `TCP:bbr`）。

---

## 卸载

菜单 `9`，删除二进制、配置、所有节点与证书。

---

## 免责声明

仅供学习与合法网络调试用途。请遵守所在地法律法规及 VPS 服务商条款。
