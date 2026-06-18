# OneVPS

[English](README.md)

VPS 一键搭建 Xray 节点脚本，主线配置为 **VLESS + TCP + REALITY + XTLS Vision + uTLS**。

这个版本从 sing-box 改为 [Xray-core](https://github.com/XTLS/Xray-core)，使用社区常见的 Reality + Vision 组合：无需域名、无需证书，客户端使用 uTLS 指纹。

---

## 特性

- **Xray-core 官方安装器**：通过 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 安装/更新核心与 geodata
- **VLESS + TCP + REALITY**：直连 VPS，Reality 借用目标站 TLS 握手特征
- **XTLS Vision**：服务端用户固定 `flow: xtls-rprx-vision`
- **uTLS**：分享链接固定 `fp=chrome`，兼容主流客户端
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

首次使用：先运行 `1` 安装/更新 Xray-core，再运行 `2` 添加 Reality 节点。

---

## 菜单

```text
1) Install / update Xray-core
2) Add node - VLESS + Reality + Vision + uTLS
3) Manage nodes
4) Show all share links
5) Restart service
6) BBR acceleration
7) System optimization
8) Uninstall
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

目标站建议满足：

- 支持 TLS 1.3 和 H2
- SNI 稳定，证书 SAN 覆盖所填域名
- 尽量选择与你 VPS 网络位置延迟较低的站点

添加或修改节点时，脚本会尝试执行 `xray tls ping` 做目标站探测；探测失败不会强制中断，但建议换一个更稳定的目标站。

---

## 节点管理

菜单 `3` 可执行：

```text
1) 修改端口
2) 重置 UUID
3) 轮换 Reality 密钥和 shortId
4) 修改 Reality 目标站
5) 启用/停用
6) 删除节点
```

轮换密钥或 shortId 后，旧客户端链接会失效，需要重新导入菜单 `4` 输出的新链接。

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

---

## BBR 与系统优化

菜单 `6` 可启用 BBR，写入 `/etc/sysctl.d/99-bbr.conf`。

菜单 `7` 应用偏保守的长期稳定型优化：

- 提高 TCP buffer 上限，但不抬高每个 socket 的默认 buffer
- 开启 TFO、MTU probing，并提高 backlog
- 将临时端口范围设为 `10000-65535`
- 可创建小 swap，限制 journald 磁盘占用
- 可切换 Xray 出站 UDP/443 阻断；默认开启以减少 QUIC/HTTP3 带来的路由和稳定性问题

---

## 卸载

菜单 `8` 会删除 Xray 二进制、配置、节点元数据、geodata 与日志目录。

BBR、系统优化配置和 swap 文件会保留。

---

## 免责声明

仅供学习与合法网络调试用途。请遵守所在地法律法规及 VPS 服务商条款。
