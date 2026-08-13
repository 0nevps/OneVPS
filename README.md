# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/0nevps/OneVPS)](https://github.com/0nevps/OneVPS/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[简体中文](README_CN.md)

OneVPS is an open-source automation tool for deploying and operating Xray nodes on Linux VPS hosts.
It turns the installation, configuration, service management, and routine maintenance steps into one
auditable Bash workflow.

Two deployment modes are supported:

- **VLESS + TCP + REALITY + XTLS Vision + uTLS** — a standalone deployment that does not require a domain
  or certificate.
- **Trojan + WebSocket behind Caddy** — a deployment that shares Caddy's `:443` listener and certificates
  with other Caddy-managed services.

OneVPS deliberately focuses on Xray-based deployments. It is not a general-purpose VPS control panel or a
replacement for infrastructure-as-code, firewall management, monitoring, or backups.

## Why OneVPS?

Operating an Xray service by hand involves more than installing a binary. Maintainers must generate secrets,
produce valid configuration, create a least-privilege systemd service, coordinate ports and firewall rules,
integrate with a TLS endpoint, and keep the resulting deployment maintainable.

OneVPS keeps those steps in a readable shell script so operators can inspect what changes will be made, repeat
the same workflow on another supported host, and contribute fixes in one place.

## Features

- **Repeatable deployment**: installs dependencies and generates Xray configuration from stored node metadata
- **Official Xray installer**: installs or updates core and geodata through
  [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- **VLESS + TCP + REALITY**: direct VPS connection with REALITY target-site TLS camouflage
- **XTLS Vision and uTLS**: generates `xtls-rprx-vision` users and share links with `fp=chrome`
- **Trojan + WS behind Caddy**: exposes only Caddy while the Xray inbound remains bound to loopback
- **Configuration validation**: validates generated Xray configuration before replacing the active file
- **Secure defaults**: random UUIDs, X25519 keys, short IDs, passwords, and WebSocket paths
- **Restricted routing**: blocks private address ranges, BitTorrent traffic, and—by default—outbound UDP/443
- **Least-privilege service**: runs Xray as `nobody` with only the low-port bind capability
- **Operations**: manages nodes and share links, restarts the service, enables BBR, and applies optional system tuning
- **Network diagnostics**: an optional recorder that samples network and service counters so intermittent
  "cannot connect" reports can be traced to the server or ruled out

> Legacy sing-box nodes are not migrated automatically. OneVPS manages Xray under `/usr/local/etc/xray/`.

## Supported Technologies

| Area | Supported options |
| --- | --- |
| Core | [Xray-core](https://github.com/XTLS/Xray-core) |
| Protocols | VLESS, Trojan |
| Transports | TCP, WebSocket |
| Security | REALITY, XTLS Vision, TLS terminated by Caddy |
| Service manager | systemd |
| Architectures | amd64, arm64, armv7 |
| Package managers | apt, dnf, yum, zypper |

## Quick Start

The script runs as root and changes system services, firewall rules, and optional kernel settings. Review the
script before running it, especially on an existing server.

Recommended release installation with checksum verification:

```bash
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/onevps.sh
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/SHA256SUMS
sha256sum --check SHA256SUMS
less onevps.sh
sudo bash onevps.sh
```

Convenience command for an already trusted environment:

```bash
bash <(curl -fsSL https://github.com/0nevps/OneVPS/releases/latest/download/onevps.sh)
```

The convenience command must be run from a root shell. On first use, select `1` to install or update Xray-core,
then select `2` for a Reality node or `3` for a Trojan + WS node.

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

## VLESS + REALITY

### Default configuration

| Item | Default |
| --- | --- |
| Protocol | VLESS |
| Transport | TCP |
| Transport security | REALITY |
| Flow | `xtls-rprx-vision` |
| uTLS fingerprint | `chrome` |
| Encryption | `none` |
| Port | `443`, or a random high port if occupied |

Share link format:

```text
vless://UUID@IP:PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=TARGET&fp=chrome&pbk=PUBLIC_KEY&sid=SHORT_ID&spx=%2F&type=tcp#NAME
```

### REALITY target selection

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

A suitable target should support TLS 1.3 and HTTP/2, have a stable SNI covered by the certificate SAN, and have
acceptable latency from the VPS network.

When a Reality node is added or edited, OneVPS runs multiple `xray tls ping` rounds against the built-in
candidates and ranks them by success rate and average latency. Operators can still select a candidate manually
or enter a custom domain. If every probe fails, the script falls back to the first candidate and displays a
warning.

## Trojan + WebSocket Behind Caddy

Menu option `3` creates a Trojan node that shares port `443` with services already managed by Caddy.

How it works:

- The Xray Trojan inbound listens on **`127.0.0.1` only**, uses WebSocket transport, and does not terminate TLS.
- Caddy terminates TLS for a dedicated subdomain and reverse-proxies a secret WebSocket path to the local inbound.
- Other Caddy sites remain untouched.
- Requests outside the secret path receive an HTTP 403 response backed by an editable page in
  `/var/lib/onevps/sites/<domain>/index.html`.
- The script appends a marked site block to the Caddyfile, validates the configuration, and reloads Caddy. A failed
  reload rolls the appended block back.
- Trojan nodes do not change firewall rules; Caddy remains the public endpoint.

Requirements:

- A dedicated subdomain with `A` or `AAAA` records pointing at the server
- Reachable ports `80` and `443` for ACME and client traffic
- Caddy, which OneVPS installs when absent using a supported package repository or a static binary fallback

Share link format:

```text
trojan://PASSWORD@SUBDOMAIN:443?security=tls&sni=SUBDOMAIN&type=ws&host=SUBDOMAIN&path=PATH#NAME
```

## Node Management

Reality node actions:

```text
1) Change port
2) Reset UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target
5) Enable/disable
6) Delete node
```

Trojan node actions:

```text
1) Reset password
2) Change domain
3) Change WS path
4) Rebuild Caddy route
5) Enable/disable
6) Delete node
```

`Rebuild Caddy route` regenerates the managed Caddy block without changing the node password, path, or port.
Rotating Reality secrets or resetting Trojan credentials invalidates old client links; import the updated link
from menu option `5`.

## Security Model

OneVPS applies several defensive defaults, but running any root-level deployment script still requires operator
review and normal server hardening.

- Node credentials and private keys are stored in `/usr/local/etc/xray/onevps-nodes.json` with restricted access.
- Generated runtime configuration is validated before activation.
- Xray runs without root privileges after installation.
- Trojan inbounds are loopback-only; Caddy is the only public TLS endpoint for that mode.
- Share links contain live credentials and must be handled as secrets.
- The installation workflow downloads upstream installers or binaries at runtime. Operators should evaluate their
  network and upstream trust requirements before execution.
- OneVPS does not configure SSH policy, unattended upgrades, intrusion detection, backups, or a complete firewall.

Report suspected vulnerabilities privately according to the [security policy](SECURITY.md).

## File Locations

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/xray` | Xray core binary |
| `/usr/local/etc/xray/config.json` | Generated Xray runtime configuration |
| `/usr/local/etc/xray/onevps-nodes.json` | Node metadata and credentials |
| `/usr/local/share/xray/` | geoip and geosite data |
| `/etc/systemd/system/xray.service` | systemd service unit |
| `/var/log/xray/` | Xray log directory |
| `/var/lib/onevps/sites/<domain>/` | Editable 403 page for a Trojan subdomain |
| `/usr/local/sbin/onevps-netwatch` | Installed copy of the diagnostics recorder |
| `/etc/onevps-netwatch.conf` | Recorder configuration, including notification tokens |
| `/var/log/onevps-netwatch.log` | Recorded samples, rotated in place |
| `/var/lib/onevps-netwatch/` | Recorder counter baselines and alert cooldowns |

Manual service management:

```bash
systemctl status xray
systemctl restart xray
journalctl -u xray -f
```

Configuration validation:

```bash
xray run -test -config /usr/local/etc/xray/config.json
```

## Requirements

- Linux with systemd
- Root access
- amd64, arm64, or armv7 architecture
- apt, dnf, yum, or zypper
- `curl`, `jq`, `openssl`, and CA certificates; missing dependencies are installed automatically
- Caddy only for Trojan + WS nodes; it is installed automatically when required

Support is best-effort because distribution releases, package repositories, Xray, and Caddy change independently.
When reporting a compatibility problem, include the distribution, version, architecture, package manager, and
sanitized command output.

## BBR and System Tuning

Menu option `7` enables BBR and writes `/etc/sysctl.d/99-bbr.conf`.

Menu option `8` applies optional, conservative tuning for long-running VPS workloads:

- Raises TCP buffer ceilings without increasing every socket's default allocation
- Enables TCP Fast Open and MTU probing and raises backlog limits
- Sets the ephemeral port range to `10000-65535`
- Can create a small swap file and cap journald disk usage
- Can toggle Xray outbound UDP/443 blocking, which is enabled by default

Review these settings against the server's other workloads before applying them.

## Network Diagnostics

`scripts/onevps-netwatch.sh` answers a question that connection reports alone cannot: when a user says the node
was unreachable at 14:30, was the server at fault, or was it the link or the client? Intermittent faults leave no
evidence unless something was already recording, so the script samples counters on a systemd timer and keeps a
timeline you can query after the fact.

It is optional and independent of node management. Nothing in `onevps.sh` requires it.

### Install

```bash
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/onevps-netwatch.sh
curl -fLO https://github.com/0nevps/OneVPS/releases/latest/download/SHA256SUMS
sha256sum --check SHA256SUMS
less onevps-netwatch.sh
sudo bash onevps-netwatch.sh install
```

Installation copies the script to `/usr/local/sbin/onevps-netwatch`, writes a mode-600 configuration file, and
starts a timer that samples every 30 seconds. It needs systemd, root, and `ss` from iproute2; `fail2ban-client`
is used when present and skipped otherwise.

### Commands

| Command | Purpose |
| --- | --- |
| `onevps-netwatch status` | Verdict for the last 24 hours, or a warning when sampling has stalled |
| `onevps-netwatch at "14:30"` | Verdict around a point in time; append a number to widen the default 10-minute window |
| `onevps-netwatch report --since 24h` | Verdict over a window given in `s`, `m`, `h`, or `d` |
| `onevps-netwatch tail` | Follow the raw log live |
| `onevps-netwatch uninstall` | Remove the timer; `--purge` also removes logs and configuration |

`status`, `at`, and `report` answer one question in plain language: was this server at fault? Each finding says
what happened, what it meant for users, and which command to run next. Add `--detail` to any of them to see the
underlying counters instead.

### Investigating a report

```bash
onevps-netwatch at "14:30"          # was this server at fault at that moment?
onevps-netwatch report --since 6h   # anything wrong in the hours around it?
```

Findings are aggregated per kind and ordered by how directly each one explains a failed connection, so a service
that went down is reported before a queue that merely came close to its limit:

```text
✗ 2 个问题 · 20分钟 / 41 次采样

  ✗ xray 停止 3分钟（14:31-14:34） · 期间连接全部失败
    → journalctl -u xray --since "14:31"
  ✗ 连接队列溢出，丢弃 37 个（14:33 起） · 涌入超过处理能力
```

When nothing is found, that is itself the answer: the server was healthy throughout the window, so the fault lay
in the link or on the client. That conclusion is the one that is hardest to reach without a recording.

### Recorded values

Behind the verdict, each sample is one `key=value` line, so the log stays greppable without extra tooling:

- conntrack usage against its limit, and kernel `table full` events
- TCP accept-queue drops and overflows, SYN retransmits, retransmission rate
- Established, TIME_WAIT, and SYN_RECV socket counts, and the number of listening sockets
- CPU, memory, and root filesystem usage
- Interface throughput and NIC drop counters
- Kernel OOM events and the fail2ban banned-address total
- Liveness and main PID of detected services, which makes silent restarts visible

Services are autodetected from `xray`, `caddy`, `nginx`, `sshd`, `ssh`, `fail2ban`, and `docker`. Set
`MONITOR_UNITS` in the configuration file to watch a different set.

### Alerts

Set `TELEGRAM_TOKEN` with `TELEGRAM_CHAT_ID`, or `WEBHOOK_URL`, in `/etc/onevps-netwatch.conf` to be notified when
conntrack passes 80 percent, the accept queue drops connections, a watched service goes down or restarts, the
kernel reports an OOM kill, or the disk passes 90 percent. Alerts are throttled per kind, by default to one push
every 30 minutes; every alert is written to the log regardless. Because the file holds notification tokens, it is
created with mode 600 and should stay that way.

## Uninstall

Menu option `9` removes the Xray binary, configuration, node metadata, geodata, and log directory.

BBR settings, system-tuning files, the swap file, Caddy, its Caddyfile, and customized site content are retained so
the script does not remove host-wide state that may be shared with other services.

The diagnostics recorder is installed separately and is removed with `onevps-netwatch uninstall`.

## Maintenance and Roadmap

Infrastructure automation must track changes across Linux distributions and upstream components. Current
maintenance priorities are:

- Keep generated Xray and Caddy configuration compatible with supported upstream releases
- Improve failure handling and make host changes easier to audit or roll back
- Expand automated coverage for configuration migrations, Caddy routes, and failure paths
- Add disposable cross-distribution integration tests for host-level operations
- Document compatibility results from different distributions and architectures
- Review runtime downloads and release-integrity controls

The CI workflow runs Bash syntax validation, ShellCheck, configuration-generation tests, and Markdownlint for
each push and pull request.

## Testing

The dependency-light test suite sources `onevps.sh`, uses fixture node metadata, and writes only to a temporary
directory. It does not modify systemd, firewall rules, or production configuration.

```bash
bash -n onevps.sh scripts/onevps-netwatch.sh tests/test_onevps.sh
shellcheck --severity=warning onevps.sh scripts/onevps-netwatch.sh tests/test_onevps.sh
bash tests/test_onevps.sh
```

## Releases

Versioned releases include `onevps.sh`, `scripts/onevps-netwatch.sh`, and a `SHA256SUMS` file covering both. See
[CHANGELOG.md](CHANGELOG.md) for release notes and compatibility-impacting changes.

## Contributing

Bug reports, compatibility results, documentation improvements, and focused pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a contribution. Do not include node URLs, UUIDs, passwords,
private keys, or unredacted server logs in public issues.

Security-sensitive reports must follow [SECURITY.md](SECURITY.md) instead of the public issue tracker.

## License

OneVPS is available under the [MIT License](LICENSE).

## Disclaimer

Use OneVPS only for lawful administration of systems and networks you are authorized to manage. You are
responsible for reviewing the script, complying with local law and provider terms, and protecting generated
credentials.
