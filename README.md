# OneVPS

[中文版](README_CN.md)

One-click Xray node deployment script for VPS. Two protocols:

- **VLESS + TCP + REALITY + XTLS Vision + uTLS** (mainline) — no domain, no certificate.
- **Trojan + WebSocket behind Caddy** — rides Caddy's `:443` + certificates, coexisting with other Caddy-proxied services.

Built on [Xray-core](https://github.com/XTLS/Xray-core). The Reality path needs no domain/cert; the Trojan path requires Caddy (auto-installed when absent).

---

## Features

- **Official Xray installer**: installs/updates core and geodata through [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- **VLESS + TCP + REALITY**: direct VPS connection with REALITY target-site TLS camouflage
- **XTLS Vision**: server users are generated with `flow: xtls-rprx-vision`
- **uTLS**: share links use `fp=chrome` for mainstream client compatibility
- **Trojan + WS behind Caddy**: loopback-only Xray inbound; Caddy terminates TLS on `:443` and reverse-proxies a secret WS path on a dedicated subdomain, coexisting with other Caddy sites. Caddy is auto-installed if missing.
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

First time: run `1` to install/update Xray-core, then run `2` for a Reality node or `3` for a Trojan + WS node.

---

## Menu

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

Recommended target properties:

- Supports TLS 1.3 and H2
- Stable SNI, with the selected domain covered by certificate SAN
- Low latency from your VPS network when possible

When adding or editing a node, the script auto-tests built-in candidates with multiple `xray tls ping` rounds and selects by success rate, then average latency. You can still select a candidate manually or enter a custom domain. If every probe fails, the script falls back to the first candidate, but you should pick a more stable target when possible.

---

## Trojan + WS (behind Caddy)

Menu `3` adds a Trojan node that lives behind Caddy, so it shares `:443` with whatever else Caddy already serves.

How it works:

- Xray Trojan inbound binds **`127.0.0.1` only** with **no TLS** (`network: ws`).
- Caddy terminates TLS on `:443`, auto-issues a certificate for a **dedicated subdomain**, and reverse-proxies a **secret WS path** to the local inbound. All other Caddy sites/paths are untouched.
- The WS path is **gated on the `Upgrade` header** — only real WebSocket handshakes reach Xray. Every other request (any path, including a plain browser GET to the WS path) returns **HTTP 403 with a styled 403 page** from `/var/lib/onevps/sites/<domain>/index.html`, so the whole subdomain looks like a locked-down site rather than a dead proxy. Replace that `index.html` with your own content anytime; the script never overwrites it.
- The firewall is not modified for Trojan nodes — only Caddy faces the internet.

Requirements:

- A subdomain with a DNS `A`/`AAAA` record pointing at this server (so Caddy can issue the cert).
- Ports `80` and `443` reachable for ACME and traffic.
- Caddy installed — if absent, the script installs it (official apt/dnf/yum repo, or a static binary + systemd unit as fallback) and creates a default Caddyfile.

The script appends a marked site block to the Caddyfile, validates, and reloads Caddy. Deleting the node removes that block and reloads again.

Share link format:

```text
trojan://PASSWORD@SUBDOMAIN:443?security=tls&sni=SUBDOMAIN&type=ws&host=SUBDOMAIN&path=PATH#NAME
```

---

## Node Management

Menu `4` actions depend on node type.

Reality node:

```text
1) Change port
2) Reset UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target
5) Enable/disable
6) Delete node
```

Trojan node:

```text
1) Reset password
2) Change domain
3) Change WS path
4) Enable/disable
5) Delete node
```

After rotating the Reality keypair/shortId or resetting a Trojan password/path, old client links stop working. Re-import the new link from menu `5`.

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
| `/var/lib/onevps/sites/<domain>/` | 403 camouflage page for a Trojan subdomain (editable) |

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
- Caddy auto-installed only when adding a Trojan node

---

## BBR and System Tuning

Menu `7` enables BBR and writes `/etc/sysctl.d/99-bbr.conf`.

Menu `8` applies conservative long-running VPS tuning:

- Raises TCP buffer ceilings without inflating each socket's default buffer
- Enables TFO and MTU probing, and raises backlog limits
- Sets ephemeral ports to `10000-65535`
- Can create a small swap file and cap journald disk usage
- Can toggle Xray outbound UDP/443 blocking; enabled by default to reduce QUIC/HTTP3 routing and stability issues

---

## Uninstall

Menu `9` removes the Xray binary, config, node metadata, geodata, and log directory.

BBR, system tuning configs, the swap file, and Caddy (with its Caddyfile) are kept.

---

## Disclaimer

For educational and legitimate network debugging purposes only. Please comply with local laws and your VPS provider's terms of service.
