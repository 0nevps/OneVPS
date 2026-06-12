# OneVPS

VPS 一键搭建代理节点脚本，基于 [sing-box](https://github.com/SagerNet/sing-box)。

支持协议：**VLESS + WebSocket** 和 **Hysteria2**。两个可选增强：

- 🟠 **Cloudflare CDN** — VLESS+WS 节点可套 CF 橙云代理，隐藏真实 IP
- 🧦 **SOCKS5 落地** — 给任意节点挂一个带认证的 SOCKS5 出口，VPS 当前置，所有流量从 SOCKS5 落地

---

## 快速开始

```bash
sudo bash onevps.sh
```

或一行远程拉取运行（替换为你的实际地址）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/<user>/OneVPS/main/onevps.sh)
```

脚本启动先做环境检测（root / 架构 / 包管理器 / systemd），通过后进入菜单。

---

## 菜单

```
1) 安装 / 更新 sing-box      从 GitHub 取最新版，自动写 systemd 服务
2) 添加节点 — VLESS + WS
3) 添加节点 — Hysteria2
4) 管理节点                  改 SOCKS5 / 切 CF / 改端口 / 重置密钥 / 启停 / 删除
5) 查看全部分享链接
6) 重启服务
7) 卸载
0) 退出
```

首次使用：先跑 `1` 安装，再 `2`/`3` 添加节点。

---

## 协议与证书

| 协议 | 传输 | CF CDN | 证书 |
|------|------|--------|------|
| VLESS | WebSocket | ✅ 可选 | 见下表 |
| Hysteria2 | QUIC / UDP | ❌ 不支持（UDP，CF 不代理） | ACME 或自签 |

证书策略（添加节点时按选择自动决定）：

| 场景 | 证书 | 客户端 |
|------|------|--------|
| 有域名 + 开 CF | 自签，CF 设 **完全(Full)** | 正常 |
| 有域名 + 不开 CF | ACME 真证书（Let's Encrypt） | 正常 |
| 无域名 | 自签 | 需开 `allowInsecure` / `insecure` |

> **为什么开 CF 用自签？** CF 橙云会拦截 ACME 的 HTTP-01/TLS-ALPN 验证，签不出真证书。
> 回源用自签 + CF 面板设 "完全(Full)"，VPS↔CF 之间仍是加密的。
> 想要 "完全(严格)/Full Strict" 需自行上传 CF Origin CA 证书，本脚本未做。

---

## Cloudflare CDN 使用要点

1. 域名先在 Cloudflare 托管，A 记录指向 VPS IP，**橙云开启**（Proxied）。
2. CF 免费版回源 HTTPS 端口仅限：`443 2053 2083 2087 2096 8443`。
   脚本在选 CF 时会强制校验，端口必须从这几个里选。
3. CF 面板 → SSL/TLS → 概述 → 加密模式选 **完全(Full)**。

---

## SOCKS5 落地

添加节点时或在「管理节点」里可挂 SOCKS5 出口：

```
SOCKS5 服务器地址: residential.example.com
SOCKS5 端口: 1080
用户名: user        (无认证留空)
密码: ******
```

挂上后该节点 **全部流量**（含 DNS）从 SOCKS5 出口落地，VPS 仅作前置中转。

> ⚠️ 无故障回落：SOCKS5 出口挂掉时该节点直接不可用。

---

## 文件位置

| 路径 | 用途 |
|------|------|
| `/usr/local/bin/sing-box` | 内核二进制 |
| `/etc/sing-box/nodes.json` | 节点元数据（脚本的真相源） |
| `/etc/sing-box/config.json` | sing-box 运行配置（由 nodes.json 自动生成） |
| `/etc/sing-box/certs/` | 自签证书 |
| `/etc/systemd/system/sing-box.service` | systemd 服务 |

手动管理服务：

```bash
systemctl status sing-box
systemctl restart sing-box
journalctl -u sing-box -f      # 看实时日志
```

---

## 环境要求

- Linux + **systemd**
- root 权限
- 架构：amd64 / arm64 / armv7
- 包管理器：apt / dnf / yum / apk（自动装 `curl jq openssl tar` 依赖）

---

## 卸载

菜单 `7`，删除二进制、配置、所有节点与证书。

---

## 免责声明

仅供学习与合法网络调试用途。请遵守所在地法律法规及 VPS 服务商条款。
