# OneVPS

[中文版](README_CN.md)

One-click Xray node deployment script for VPS. The mainline configuration is **VLESS + TCP + REALITY + XTLS Vision + uTLS**.

This version replaces sing-box with [Xray-core](https://github.com/XTLS/Xray-core) and uses the common Reality + Vision setup: no domain, no certificate, and a uTLS client fingerprint.

---

## Features

- **Official Xray installer**: installs/updates core and geodata through [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- **VLESS + TCP + REALITY**: direct VPS connection with REALITY target-site TLS camouflage
- **XTLS Vision**: server users are generated with `flow: xtls-rprx-vision`
- **uTLS**: share links use `fp=chrome` for mainstream client compatibility
- **Secure defaults**: random UUID, X25519 keypair, 16-hex shortId, private IP blocking, BitTorrent blocking, UDP/443 blocking
- **Hardened service**: systemd runs Xray as `nobody` with only low-port bind capability
- **Operations**: node management, share links, BBR, basic system tuning

> Old sing-box nodes are not migrated automatically. This script now manages Xray under `/usr/local/etc/xray/`.

---

## Quick Start

One-liner:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh)
```

Or download and run locally:

```bash
sudo bash onevps.sh
```

First time: run `1` to install/update Xray-core, then run `2` to add a Reality node.

---

## Menu

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

## Node Configuration

| Item | Default |
|------|---------|
| Protocol | VLESS |
| Transport | TCP |
| Transport security | REALITY |
| Flow | `xtls-rprx-vision` |
| uTLS fingerprint | `chrome` |
| Encryption | `none` |
| Default port | `443`, random if occupied |

Share link format:

```text
vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=TARGET&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&type=tcp#NAME
```

---

## Reality Target

Built-in candidates:

- `www.microsoft.com`
- `www.apple.com`
- `www.samsung.com`
- `gateway.icloud.com`
- `www.lovelive-anime.jp`

Recommended target properties:

- Supports TLS 1.3 and H2
- Stable SNI, with the selected domain covered by certificate SAN
- Low latency from your VPS network when possible

When adding or editing a node, the script tries `xray tls ping` to probe the target. A failed probe does not force abort, but you should pick a more stable target when possible.

---

## Node Management

Menu `3` supports:

```text
1) Change port
2) Reset UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target
5) Enable/disable
6) Delete node
```

After rotating the keypair or shortId, old client links stop working. Re-import the new link from menu `4`.

---

## File Locations

| Path | Purpose |
|------|---------|
| `/usr/local/bin/xray` | Xray core binary |
| `/usr/local/etc/xray/config.json` | Generated Xray runtime config |
| `/usr/local/etc/xray/onevps-nodes.json` | Node metadata |
| `/usr/local/share/xray/` | geoip/geosite data |
| `/etc/systemd/system/xray.service` | systemd service |
| `/var/log/xray/` | Xray log directory |

Manual service management:

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -f
```

Config validation:

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

---

## Requirements

- Linux + systemd
- Root access
- Architecture: amd64 / arm64 / armv7
- Package manager: apt / dnf / yum / zypper
- Dependencies auto-installed: `curl` `jq` `openssl`

---

## BBR and System Tuning

Menu `6` enables BBR and writes `/etc/sysctl.d/99-bbr.conf`.

Menu `7` applies basic TCP/UDP buffer, TFO, backlog, swap, and journald cap tuning.

---

## Uninstall

Menu `8` removes the Xray binary, config, node metadata, geodata, and log directory.

BBR, system tuning configs, and the swap file are kept.

---

## Disclaimer

For educational and legitimate network debugging purposes only. Please comply with local laws and your VPS provider's terms of service.
