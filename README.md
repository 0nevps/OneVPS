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
- **Restricted routing**: blocks private address ranges and BitTorrent traffic
- **Least-privilege service**: runs Xray as `nobody` with only the low-port bind capability
- **Operations**: manages nodes and share links, restarts the service, enables BBR, and applies optional TCP tuning

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

Stable version tags are published automatically after CI validation, with the script and checksum assets.
See [release procedures](CONTRIBUTING.md#releases) for manual backfills.

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
5) Show default node share links
6) Restart service
7) BBR acceleration
8) TCP optimization
9) Uninstall
10) Realm relay
0) Exit
```

## Node outbounds

Choose **Set node outbound** (`8`) from a node's management menu, select **All users** or
**Selected users**, then choose an explicit **Direct** connection, paste one proxy link
(visible input; credentials appear on screen), or restore the default setting.

- **Selected users:** select one or more users on the current node, including its default client.
  Only the selected identities change. Restoring the default removes their overrides so they inherit
  the node outbound again.
- **All users:** set the node outbound and clear every user override on that node, including the
  default client's override. Newly added users inherit this outbound too. Restoring the default clears
  both the node outbound and all user overrides, returning to default direct access.
- Routing priority is safety blocks, user override, node outbound, then default direct access.
  An explicit direct override bypasses the node's proxy outbound, but not safety blocks.
  Operations never change another node's users or outbounds.

Supported links:

- **Shadowsocks:** SIP002 with `aes-128-gcm`, `aes-256-gcm`, or `chacha20-ietf-poly1305`;
  Base64URL `method:password` userinfo or percent-encoded plain userinfo.
  SS2022, plugins, and legacy whole-link Base64 encoding are not supported.
- **VLESS:** TCP + Reality, or TCP / WebSocket / gRPC + TLS. This includes OneVPS-generated
  TCP + Reality + Vision links. Unsupported transports, encryption options, and insecure TLS options
  are rejected rather than silently ignored.
- **SOCKS5:** `socks5://host:port` or `socks5://username:password@host:port`.
  Percent-encode reserved characters in credentials. `socks://` and `socks5h://` are not supported.

VLESS parameters are limited to `encryption`, `type`, `security`, `flow`, `sni`, `fp`, `pbk`, `sid`,
`spx`, `host`, `path`, `serviceName`, `mode`, and `alpn`, and must fit the selected transport.
Reality requires `sni`, `fp`, `pbk`, and `sid`; TLS does not accept Reality-only fields.
`type` defaults to `tcp`, `encryption` to `none`, and `flow` to empty. Vision is TCP-only;
gRPC `mode` accepts `gun` or `multi`. `alpn` accepts `h2` and/or `http/1.1` for TLS.
WebSocket `path` is a literal path, not an early-data configuration. Unknown or duplicate keys are rejected.

All formats accept a hostname, IPv4, or bracketed IPv6 address, an explicit port, and an optional `#name`.
For example, `socks5://test:example%3Apassword@proxy.example.com:1080#Example` uses fictional credentials.
Only one link is accepted; this is not a subscription importer or an arbitrary Xray JSON editor.

Existing private-address and BitTorrent blocks run **before** outbound selection.
Proxy failure does not automatically fall back to direct access. SOCKS5 does not encrypt traffic or
credentials; use it only over a trusted/protected path. UDP availability depends on the upstream protocol
and server, not merely on a valid link.

Outbound changes require an installed Xray binary and successful configuration validation before activation.
They preserve backups and restart Xray, which may start a previously stopped service. Detected activation
failures restore the previous metadata/configuration and attempt to restore the previous service state.
Recovery failures are reported separately; this is not a guarantee against power loss during file replacement.
Invalid links or failed validation leave the active files untouched.
Normalized proxy settings contain secrets in the metadata, generated configuration, and any recovery backups;
protect these files. Upstream credentials are not added to client share links. Older scripts may ignore
outbound settings and restore direct routing when rebuilding; do not downgrade and rebuild if the selected
exit must be preserved.

The independent core check requires a real binary and fails if it is missing:

```bash
XRAY_TEST_BIN=/absolute/path/to/xray bash tests/test_xray_outbounds.sh
```

CI runs this check with Xray `26.3.27`. Configuration acceptance is not proof of upstream reachability;
verify traffic through your intended exit separately.

## Node-local users

Use the user management entry in a node's menu to add users, delete users, and display individual
share links. Users belong only to that node; there are no global accounts or cross-node assignments.
Different nodes may use the same user name. Each new Reality user gets an independent UUID, and each
Trojan user gets an independent password. New users inherit the node outbound.
Names, user IDs, and credentials must be unique within the node; credentials must not collide with
its default client either.

The original default client and share link are preserved. This reserved identity cannot be deleted
through the user menu; its credentials remain managed by the existing node reset options.
Deleting an added user requires confirmation. After successful application, that user's credentials
and link no longer grant access, and their dedicated outbound rules are removed without changing other users.

User additions, deletions, and outbound changes use the same candidate validation and transactional
rollback flow, require an installed Xray binary, and restart the service. User share links contain
access credentials and should be treated as secrets; they never contain upstream outbound credentials.

### Compatibility with former global users

New node-local users are stored in `.nodes[].users`. Legacy top-level `users` and node `clients`
fields remain preserved but ignored. They are not automatically migrated, cleaned up, or reactivated.
Add any users who still need access to their intended node and distribute their new links.
Replacing the script alone does not change the running Xray configuration. On the next configuration
rebuild and application, legacy extra clients and their routes are not retained, and their old links
no longer authorize access.

Back up `onevps-nodes.json` and `config.json` before deployment. Restoring an older script and rebuilding
may reactivate retained global users while ignoring new node-local users and outbound overrides.
Do not downgrade to preserve this version's access controls or outbound settings.

## Realm port relay

Choose menu `10`, then `1` to install realm and add a relay without installing Xray.
Enter a local port, destination IP or hostname, destination port, and `tcp` (default) or `both` (TCP+UDP).
For example, forward local port `10443` to `203.0.113.20:443` using TCP.
Destinations support IPv4, hostnames, and IPv6 literals without brackets; listeners bind to `0.0.0.0` (IPv4).

**Security:** realm forwards traffic without adding authentication or encryption. Only expose intended ports,
restrict source addresses in your firewall where appropriate, and retain the destination protocol's security.
Manually allow the listening port in the host firewall and cloud security group. OneVPS does not change these rules.
Existing Xray share links are not rewritten; preserve destination TLS/Reality server names when configuring clients.

The submenu lists rules and service status, deletes rules, restarts the service, and uninstalls realm independently.
Deleting the last rule stops and disables the service. Failed rule activation restores the previous configuration
and attempts to restore the previous service state. A successful local listener check does not prove destination
reachability: test from a client and inspect `journalctl -u onevps-realm` if forwarding fails.

Installation uses the official [realm v2.9.6 release](https://github.com/zhboner/realm/releases/tag/v2.9.6),
verifies the archive against the GitHub release asset's SHA-256 digest, and supports amd64, arm64, and armv7.
The pinned release is reused on subsequent additions, not automatically upgraded.
Requires systemd with `DynamicUser` support (232+), `tar`, and `ss` from `iproute2` (Debian/Ubuntu) or
`iproute` (RHEL-family). The service runs with a dynamic unprivileged user and permission to bind low ports.

| Resource | Location |
| --- | --- |
| Binary | `/usr/local/bin/onevps-realm` |
| Configuration | `/usr/local/etc/onevps-realm/config.json` |
| Ownership marker | `/usr/local/etc/onevps-realm/.onevps-managed` |
| Service | `/etc/systemd/system/onevps-realm.service` |

Existing unmanaged files at these paths are not overwritten. Other realm installations are left alone, but may
conflict on listening ports. Menu `9` only uninstalls Xray; remove realm using menu `10` → `5`.

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
8) Set node outbound
```

Trojan node actions:

```text
1) Reset password
2) Change domain
3) Change WS path
4) Rebuild Caddy route
5) Enable/disable
6) Delete node
8) Set node outbound
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

## BBR and TCP Tuning

Menu option `7` enables BBR and writes `/etc/sysctl.d/99-bbr.conf`. Status distinguishes the default qdisc
from the interface's actual queues. Existing fq is unchanged; only a single default `pfifo_fast` root
(handle `0:`, without filters) is eligible for replacement. Custom, multiqueue, fq_codel and unknown layouts
are preserved. The already-enabled BBR path does not change queues.

Menu option `8` writes optional TCP settings to `/etc/sysctl.d/99-onevps-tune.conf`:

- Raises TCP buffer ceilings to `67108864`, preserving each current minimum and initial value after validation
- Rejects unreadable/invalid triples or initial values above the target without overwriting the old file
- Enables TCP Fast Open (requires application support) and MTU probing, and raises backlog limits
- Sets the ephemeral port range to `10000-65535`; shared socket/backlog/port settings may affect non-TCP traffic
- Uses `tcp_notsent_lowat` as an unsent-data readiness threshold, not a hard cap on all send memory

Buffer ceilings are not preallocated and these settings do not guarantee a speedup. A file's existence does
not prove runtime activation. Failed writes or sysctl loads are reported; a failed load may partially apply
settings and does not trigger an atomic rollback. Unsupported keys are reported as failures too.

Swap creation, swappiness, journald limits, conntrack tuning, slow-start-after-idle and FIN timeout overrides
are no longer part of this option. Existing swap, fstab and journald files are not removed, and previously
applied runtime values are not reset to guessed defaults. Reapplying updates only OneVPS's tuning file.

OneVPS no longer adds or offers a toggle for the default UDP/443 block. Legacy `block_udp443` metadata is
ignored and retained. An installed Xray configuration loses the old rule only after regeneration and successful
application; this does not guarantee QUIC support in clients, upstreams or the network. Private-address,
BitTorrent and node/user outbound rules remain. Review settings against other server workloads before applying.

## Uninstall

Menu option `9` removes the Xray binary, configuration, node metadata, geodata, and log directory.

BBR settings, system-tuning files, the swap file, Caddy, its Caddyfile, and customized site content are retained so
the script does not remove host-wide state that may be shared with other services.

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
bash -n onevps.sh tests/test_onevps.sh
shellcheck --severity=warning onevps.sh tests/test_onevps.sh
bash tests/test_onevps.sh
```

## Releases

Versioned releases include `onevps.sh` and a `SHA256SUMS` file. See [CHANGELOG.md](CHANGELOG.md) for release notes
and compatibility-impacting changes.

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
