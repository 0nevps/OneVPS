# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/0nevps/OneVPS)](https://github.com/0nevps/OneVPS/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[简体中文](README_CN.md)

OneVPS is an open-source automation tool for deploying and operating Xray or sing-box nodes on Linux VPS hosts.
It turns the installation, configuration, service management, and routine maintenance steps into one
auditable Bash workflow.

Four deployment modes are supported:

- **VLESS + TCP + REALITY + XTLS Vision + uTLS** — a standalone deployment that does not require a domain
  or certificate.
- **Trojan + WebSocket behind Caddy** — a deployment that shares Caddy's `:443` listener and certificates
  with other Caddy-managed services.
- **Hysteria2 + QUIC + TLS** — a native Xray inbound with Caddy-managed certificates.
- **VMess AEAD + WebSocket behind Caddy** — UUID authentication with Caddy-managed TLS.

Xray remains the full-featured mode; sing-box currently supports one node each for VLESS + REALITY + Vision,
Hysteria2, Trojan + WebSocket and VMess AEAD + WebSocket.
Core installations are exclusive: this release does not migrate or run Xray and sing-box together.
OneVPS is not a general-purpose VPS control panel or a
replacement for infrastructure-as-code, firewall management, monitoring, or backups.

## Sing-box preview

On a fresh host, select **7 → 1** to install the pinned sing-box 1.14.4 release, then **2** in the
sing-box menu to add one VLESS + REALITY + Vision node. Select **6** for Hysteria2, **7** for
Trojan + WebSocket, or **8** for VMess AEAD + WebSocket behind Caddy.
The release archive is verified with its
SHA-256 digest before installation. Existing Xray installations or node data prevent switching;
back up and migrate manually on a separate host rather than deleting data to bypass this check.
Sing-box menu **10** manages nodes: change the listen port or default credential, enable/disable,
show the share link, or delete a node. User accounts and user-specific outbounds are not supported yet.
WS nodes remove only their own Caddy routes when disabled or deleted; Caddy domain sites and certificates remain.
The menu can also display all links, restart the service, update the script, and uninstall its own files.
For Trojan or VMess over WS, Caddy owns public TLS and proxies the generated path to a loopback-only sing-box
inbound without TLS. A failed node creation or Caddy route update restores the previous node configuration
and route; the domain site and certificate remain managed by Caddy.
VMess uses `alterId=0` (AEAD) and the existing v2rayN v2 share-link format.

Sing-box [supports native ACME certificate issuance](https://sing-box.sagernet.org/configuration/shared/certificate-provider/acme/)
through the certificate provider introduced in 1.14.0. The official 1.14.4 build includes `with_acme`,
but **this preview does not use it**: REALITY needs no certificate, and Hysteria2 uses the
existing Caddy-managed certificate deployment. Caddy remains the sole issuer and renewer.
Sing-box's HY2 inbound reads the deployed PEM paths; certificate updates are validated against
the active core and rolled back if validation or service restart fails. Caddy must have access to
public TCP 80/443, and the HY2 UDP port must be permitted by the host and cloud firewalls.
On shared Caddy `:443` listeners, reserving UDP 443 for HY2 disables Caddy HTTP/3 after confirmation.
The Xray certificate flow is unchanged.

For source changes, edit `src/entry.sh` or `src/cores/*.sh`, then run
`bash scripts/build.sh --write` and `bash tests/test_build.sh`. The committed `onevps.sh` remains
the standalone download and release asset.

## VMess (AEAD, WebSocket + TLS)

Choose **2 → 6** to add a VMess node. Point a domain at the VPS and allow TCP 80/443.
Caddy terminates TLS on port 443 and proxies the secret WS path to a loopback-only Xray inbound.
The existing Caddy setup policy applies, including its shared-listener HTTP/3 restriction.
Menu **2 → 4** manages UUIDs, users, domains, paths, routes, outbounds and node state;
**2 → 5** exports links. Existing menu numbers are unchanged. Deleting a node keeps its
domain site and certificate automation. VMess route/config updates roll back on detected failures.

Share links use the v2rayN v2 `vmess://BASE64(JSON)` format with `aid=0` and `scy=auto`.
Upstream import accepts that format with TCP or WS **and TLS**, AEAD (`aid=0`), and
`auto`, `aes-128-gcm` or `chacha20-poly1305` encryption. Standard/Base64URL encoding,
numeric/string ports and formatted JSON are accepted. Unknown fields, nonzero alterId,
insecure TLS, TCP HTTP camouflage and unsupported transports are rejected, not downgraded.
URI-style VMess links, plaintext upstreams, gRPC and XHTTP are not included.

Keep client and server UTC clocks within 120 seconds. VMess is offered for compatibility;
current Xray warns about its lack of forward secrecy, and its WS documentation recommends
XHTTP to avoid WS traffic fingerprints. This feature does not migrate existing nodes.
Configuration uses the compatibility `clients`/`vnext` fields, tested against real Xray cores.

References: [VMess inbound](https://xtls.github.io/config/inbounds/vmess.html),
[VMess outbound](https://xtls.github.io/config/outbounds/vmess.html),
[WebSocket](https://xtls.github.io/config/transports/websocket.html),
[Xray 26.10.21 schema](https://github.com/XTLS/Xray-core/blob/v26.10.21/infra/conf/vmess.go),
[v2rayN link implementation](https://github.com/2dust/v2rayN/blob/master/v2rayN/ServiceLib/Handler/Fmt/VmessFmt.cs).

```bash
bash tests/test_vmess.sh
XRAY_TEST_BIN=/absolute/path/to/xray bash tests/test_vmess.sh
```

The optional real-core test needs Python 3 and verifies WS backend traffic, two UUIDs,
invalid-UUID rejection and per-user SOCKS routing. It does not test Caddy TLS termination
or Linux systemd/firewall integration; verify those on the deployment host.

## Hysteria2 (native Xray)

Update Xray using menu **1**, then choose **2 → 3** to add a HY2 node. OneVPS requires
**Xray >= 26.10.21**, the tested baseline, not the first release supporting HY2.
No separate Hysteria binary or service is installed. Existing VLESS/Trojan-only
configurations do not acquire this version requirement.

Caddy is required for both Trojan and HY2 and is the sole certificate issuer/renewer.
Create either node first: the domain has one persistent HTTPS site, and Trojan routes
are imported from `/etc/onevps-caddy/routes/<domain>/`. Deleting a node keeps the domain
and its certificate automation, so the other protocol continues working.
Use DNS-only records pointing at the server and allow inbound TCP 80/443. Caddy's
configured issuer and terms apply; OneVPS no longer installs or invokes acme.sh.

OneVPS asks before configuring the shared `:443` listener for HTTP/1.1 and HTTP/2 only,
reserving UDP 443 for HY2. This also disables HTTP/3 for other sites sharing that listener.
Conflicting global configuration, unsupported storage, and unknown existing domain sites
are rejected rather than silently overwritten. Local filesystem storage is required;
its root is resolved from Caddy configuration or the running service environment.

`onevps-caddy-sync.timer` checks every minute. It copies only the requested domain's
certificate/key, validates them, and atomically deploys them under
`/etc/onevps-certs/<domain>/current/` with restricted access for Xray's `nobody` user.
Changed certificates restart Xray; validation/restart failures restore the previous pair.
Caddy alone decides when to renew. Menu **3** provides status, domain setup, sync retries,
and Caddy/sync logs. Initial issuance waits up to about one minute; retry if still pending.

This workflow targets new deployments. It does not migrate old certificate configuration,
change old ACME timers, or adopt unknown existing domain sites. New nodes use Caddy only.
Existing externally managed PEM files remain the external owner's responsibility.
Uninstalling Xray disables certificate synchronization but retains Caddy, domain sites
and certificates. Remove unused domains manually only after checking all consumers.
Firewall allowances are retained to avoid disrupting other services.

HY2 listens on IPv4 UDP and can share port 443 with Caddy's TCP listener.
Allow the chosen UDP port in your provider security group as well as the host firewall.
Do not publish an AAAA record for an IPv4-only endpoint. BBR/TCP tuning is not QUIC tuning.

Menu **2 → 4** supports changing the UDP port, resetting the default password, managing users,
selecting node/user outbounds, enabling/disabling and deleting the node. Updates use the
existing validation/restart/rollback transaction. Menus **2 → 4/5** emit URL-encoded
`hysteria2://` links without disabling TLS verification. Existing supported outbound types
remain unchanged; importing HY2 as an upstream, obfuscation and port hopping
are not included in this implementation.

Implementation references: [Xray HY2 inbound](https://xtls.github.io/en/config/inbounds/hysteria.html),
[QUIC transport](https://xtls.github.io/en/config/transports/hysteria.html),
[official server example](https://github.com/XTLS/Xray-examples/blob/main/Hysteria2/server.jsonc)
and [share URI specification](https://v2.hysteria.network/docs/developers/URI-Scheme/).

```bash
bash tests/test_hysteria2.sh
bash tests/test_acme.sh
XRAY_TEST_BIN=/absolute/path/to/xray bash tests/test_hysteria2.sh
```

The second command requires Python 3 and OpenSSL. It exercises real TCP/UDP loopback
traffic, two user credentials, rejection of invalid credentials and per-user SOCKS routing.
Only disposable test configurations permit loopback destinations; production private-IP
blocking remains intact. Linux systemd, certificate permissions and external firewall
reachability still require deployment verification.

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
| Protocols | VLESS, Trojan, Hysteria2, VMess |
| Transports | TCP, WebSocket, QUIC (UDP) |
| Security | REALITY, XTLS Vision, TLS terminated by Caddy |
| Service manager | systemd |
| Architectures | amd64, arm64, armv7 |
| Package managers | apt, dnf, yum, zypper |

## Quick Start

The script runs as root and changes system services, firewall rules, and optional kernel settings. Review the
script before running it, especially on an existing server.

Stable version tags are published automatically after CI validation, with the script and checksum assets.
See [release procedures](CONTRIBUTING.md#releases) for manual backfills.

Download the script from the repository's `main` branch and review it before running:

```bash
curl -fLO https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh
less onevps.sh
sudo bash onevps.sh
```

This URL tracks `main`, not a fixed release. Release `SHA256SUMS` files apply only to their matching release
assets, not this repository download.

Convenience command for an already trusted environment:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps.sh)
```

The convenience command must be run from a root shell. On first use, select `1` to install or update Xray-core,
then select `2` for a Reality node or `3` for a Trojan + WS node.

## Menu

The main menu groups tasks into categories; node and service actions live in dedicated submenus.
Node users and outbounds are under `4`, then select a node and choose `7` or `8`.
Destructive actions are separated under **Danger zone** and retain their confirmation prompts.

```text
Setup / management:
 1) Install / update Xray-core
 2) Nodes / users / outbound / share links
 3) Certificates (Caddy-managed)
 4) Realm relay
 5) Service / network

Script:
 6) Update script
   7) Use sing-box (new installation only)

Danger zone:
 9) Uninstall Xray (keep Realm / Caddy)

 0) Exit
```

Option `6` (**Update script**) downloads OneVPS from the repository `main` branch after confirmation,
checks Bash syntax, and starts the updated menu. No script version is displayed. A local script is replaced
only after validation; a streamed launch uses a temporary script for the current session. Download or
validation failures leave the current script unchanged. Updating the script does not update Xray or Realm.

## Long-running operations

- Downloads show curl's transfer progress bar in interactive terminals.
- Package installation, Xray installation/updates, service start/reload/restart, public IP lookup, and
  Reality probes show an activity indicator with elapsed seconds when stderr is a terminal.
- Reality auto-selection reports the current target and round, plus completed probes and a percentage.
  This percentage counts finished probes; it does not estimate remaining time or target success rate.
- Progress goes to stderr, leaving command output unchanged. Redirected output and `TERM=dumb` use plain
  start/result lines without animation. Existing command output and errors remain visible.

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

VMess upstream import is also available; see the VMess section for its strict v2 JSON/TLS subset.

CI runs this check with Xray `26.3.27`. Configuration acceptance is not proof of upstream reachability;
verify traffic through your intended exit separately.

## Node-local users

Use the user management entry in a node's menu to add users, delete users, and display individual
share links. Users belong only to that node; there are no global accounts or cross-node assignments.
Different nodes may use the same user name. Each new Reality or VMess user gets an independent UUID, and each
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

Choose menu `4`, then `1` to install realm and add a relay without installing Xray.
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
conflict on listening ports. Menu `9` only uninstalls Xray; remove realm using menu `4` → `5`.

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

Menu `2` → `2` creates a Trojan node that shares port `443` with services already managed by Caddy.

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
Connection settings:
1) Change port
2) Reset default UUID
3) Rotate Reality keypair / shortId
4) Change Reality handshake target

Users / outbound:
7) Manage node users
8) Set node outbound

Node status:
5) Enable/disable node

Danger zone:
6) Delete node

0) Back
```

Trojan node actions:

```text
Connection settings:
1) Reset default password
2) Change domain
3) Change WS path
4) Rebuild Caddy route

Users / outbound:
7) Manage node users
8) Set node outbound

Node status:
5) Enable/disable node

Danger zone:
6) Delete node

0) Back
```

`Rebuild Caddy route` regenerates the managed Caddy block without changing the node password, path, or port.
Rotating Reality secrets or resetting Trojan credentials invalidates old client links; import the updated link
from menu `2` → `5`.

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

Menu `5` → `2` enables BBR and writes `/etc/sysctl.d/99-bbr.conf`. Status distinguishes the default qdisc
from the interface's actual queues. Existing fq is unchanged; only a single default `pfifo_fast` root
(handle `0:`, without filters) is eligible for replacement. Custom, multiqueue, fq_codel and unknown layouts
are preserved. The already-enabled BBR path does not change queues.

Menu `5` → `3` writes optional TCP settings to `/etc/sysctl.d/99-onevps-tune.conf`:

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
