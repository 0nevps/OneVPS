# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[简体中文](README_CN.md)

OneVPS is a Bash tool for deploying and operating **sing-box v1.14.3** nodes on Linux VPS hosts.

> `main` is being rewritten for sing-box. Implementation and validation are in progress; this is not a claim of
> production readiness. This README describes the new implementation's scope, not the behavior of older releases.
> The former Xray implementation is retained on the local `archive/xray` branch, which has not yet been pushed.

## Scope

- **VLESS + TCP + REALITY + Vision**: standalone deployment without your own domain or certificate;
  client links use `xtls-rprx-vision` and the `chrome` uTLS fingerprint.
- **Hysteria 2 + native ACME**: standalone UDP, automatic HTTP-01 certificate management and optional salamander.
- Node-local users, independent credentials and share links, node outbounds and per-user outbound overrides.
- Candidate configuration validation, service management, independent Realm relays, BBR and optional TCP tuning.

No traffic accounting, subscriptions, web panel, configuration migration, or dual-core operation is provided.
This is not a replacement for host hardening, firewall administration, monitoring, or backups.

## Fresh installation only

The new implementation uses its own paths and metadata with **`schema_version: 1`**. It does not import or
convert Xray or legacy sing-box installations. On old-configuration or service conflicts, the operation stops;
it does not automatically overwrite files, remove old installations, or stop another service to take its place.
Back up existing deployments and resolve conflicts explicitly before proceeding. Do not reuse old metadata.

Requirements: Linux with systemd, root access, amd64/arm64/armv7, and apt/dnf/yum/zypper.
Dependencies include Bash, `curl`, `jq`, OpenSSL, CA certificates, archive and SHA-256 tools.
Distribution and architecture compatibility still needs runtime validation.

### Obtaining the script

During development, inspect a specific `main` commit in a disposable environment:

```bash
git clone https://github.com/0nevps/OneVPS.git
cd OneVPS
git switch main
git rev-parse HEAD
less onevps.sh
sudo bash onevps.sh
```

The script runs as root and can change services, firewall rules and optional kernel settings.
Use the install-core menu entry first, then add a Reality or Hysteria 2 node.
The core is pinned to the official **sing-box v1.14.3** release, not a floating latest version;
installation verifies the downloaded archive's SHA-256 before installing it. Verification failure must stop installation.

Versioned OneVPS releases include `onevps.sh` and `SHA256SUMS`. **Older releases may still use Xray**;
check the release notes before downloading. Once a sing-box release is available, download both assets from
that same version into a clean directory, run `sha256sum --check SHA256SUMS`, inspect the script, then execute it.
Checksums detect corruption but do not independently establish the publisher's identity.
See [release procedures](CONTRIBUTING.md#releases); [CHANGELOG.md](CHANGELOG.md) retains historical release notes.

## Hysteria 2 and native ACME

Menu **11** adds a Hysteria 2 node using the pinned core's `with_quic` and `with_acme` features.
Use menu **1** first to update an existing OneVPS service unit with the writable ACME storage allowance.
No Caddy or separate ACME client is required. The initial implementation requires a domain with an A record
pointing directly to this VPS, `getent`, `ss`, and publicly reachable TCP/80 for HTTP-01 issuance and renewal.
Verify any AAAA record also reaches the host; DNS preflight checks IPv4 and does not prove external reachability.
Another service owning TCP/80 is a conflict; OneVPS never stops it automatically.

Certificates use Let's Encrypt, with TLS-ALPN-01 disabled to avoid taking Reality's TCP/443.
Public issuance discloses the domain to the CA and certificate transparency logs; the creation menu asks first.
Hysteria 2 listens on IPv4 UDP, independently of TCP listeners. UDP/443 may already belong to an HTTP/3 service;
choose another UDP port rather than stopping that service. Cloud security groups must allow the selected port.
Optional salamander obfuscation is supported. Share links use `hysteria2://` with verified TLS, not `insecure=1`.
Node-local users and layered outbounds work as with the existing protocols; HY2 outbound-link import is not included.

ACME accounts, certificates and private keys persist in `/var/lib/onevps-acme`, writable by the service user
and excluded from ordinary configuration rollback. Enabled nodes sharing a domain share a certificate provider
and must use the same ACME email. Renewal and certificate reload are managed by the running core.
When no enabled node references a domain, its provider is omitted and renewal stops until it is enabled again.
Stopping or uninstalling the core also stops renewal. Node deletion and uninstall retain ACME storage for manual
backup/cleanup; no recursive deletion of private keys is performed. TCP/80 and HY2 UDP firewall allowances are
retained after failure, port changes and deletion to avoid removing shared rules; review them manually.

Applying a configuration with enabled HY2 nodes starts a disposable loopback client and waits approximately
90 seconds per node for a trusted TLS/QUIC connection and HTTPS request to `https://www.example.com/` through
that node's default-user outbound. Failure rolls back configuration and service state, not CA issuance or firewall
allowances. This probe requires working egress and does not prove public UDP reachability or every user's route.
A newly issued certificate may remain in ACME storage after rollback. Configuration checks alone do not issue
certificates. DNS-01, self-signed deployment, port hopping and domain-edit menus are outside this first release.

Local v1.14.3 tests cover generated ACME configuration checks and HY2 TCP/UDP forwarding, identity routing,
wrong credentials/TLS names, salamander, private-address rejection and deleted-user rejection. Runtime tests
replace ACME with an explicitly trusted disposable localhost certificate and never contact a public CA.
Real public issuance, renewal, Linux service permissions/firewall behavior and cross-client interoperability
remain unverified; use an authorized disposable host and ACME staging before production acceptance.

## Users, outbounds and links

Users belong to one node, not a global account pool. Each additional Reality user receives an independent UUID;
each Hysteria 2 user receives an independent password. Names and credentials must be unique within the node.
The reserved default client is managed through the node's reset actions, not deleted through the user menu.
Deleting an added user revokes its access and removes its outbound override after successful application.

Outbound selection follows **safety blocks → user override → node outbound → direct**:

- **Selected users** changes only selected identities on the current node, including its default client.
  Restoring the default removes their overrides so they inherit the node outbound.
- **All users** sets the node outbound and clears all user overrides on that node. New users inherit it.
  Restoring the default clears both levels and returns to direct access.
- Explicit **Direct** overrides a node proxy, but never private-address or BitTorrent safety blocks.
  A failed upstream does not automatically fall back to direct access. Other nodes remain unchanged.

Paste one outbound link at a time; input is visible and may expose credentials on screen.

| Link | Accepted scope |
| --- | --- |
| `ss://` | SIP002; `aes-128-gcm`, `aes-256-gcm`, `chacha20-ietf-poly1305` only |
| `socks5://` | Host and port, with optional percent-encoded username/password |
| `vless://` | TCP + REALITY; TCP, WebSocket or gRPC + TLS; gRPC `mode=gun` only |

Shadowsocks accepts Base64URL or percent-encoded plain userinfo, not SS2022, plugins or whole-link Base64.
VLESS rejects `spx`, gRPC `mode=multi`, XHTTP, insecure TLS options, unknown/duplicate parameters and
transport-incompatible fields. Vision is TCP-only. WebSocket paths are literal paths, not early-data settings.
SOCKS5 does not encrypt traffic or credentials; use a trusted/protected path. UDP support depends on the upstream.

Share links contain client access credentials, never upstream proxy credentials. Protect links, metadata,
runtime configuration and backups. Changes require a successful real-core `check` before activation and may
restart a stopped service. Activation failures require rollback of metadata/configuration and an attempt to
restore the previous service state; this is not a power-loss-safe transaction guarantee.

## Files and operations

| Resource | Location |
| --- | --- |
| Pinned core | `/usr/local/bin/onevps-sing-box` |
| Runtime configuration | `/usr/local/etc/onevps/config.json` |
| Node metadata and secrets | `/usr/local/etc/onevps/onevps-nodes.json` (`schema_version: 1`) |
| Service unit | `/etc/systemd/system/onevps-sing-box.service` |

```bash
/usr/local/bin/onevps-sing-box version
/usr/local/bin/onevps-sing-box check -c /usr/local/etc/onevps/config.json
systemctl status onevps-sing-box.service
systemctl restart onevps-sing-box.service
journalctl -u onevps-sing-box.service -f
```

Generated configuration is validated before activation. The core runs unprivileged with permission to bind low
ports; credentials require restricted file permissions.
Uninstalling the core is separate from removing Realm; external services and host-wide tuning settings are preserved.

## Realm, BBR and TCP

**Realm** is independent of sing-box. It relays TCP or TCP+UDP from an IPv4 listener to an IPv4/IPv6/hostname
endpoint without adding authentication or encryption. Open only intended ports in the host firewall and cloud
security group; relay setup does not do this for you. Client links are not rewritten; preserve TLS/REALITY names.

Realm uses the official pinned `v2.9.6` archive with SHA-256 verification and requires systemd `DynamicUser`
support, `tar` and `ss`. It uses `/usr/local/bin/onevps-realm`,
`/usr/local/etc/onevps-realm/config.json` and `onevps-realm.service`; unmanaged files are not overwritten.
Manage and uninstall it from its own submenu. A listening port does not prove destination reachability.

**BBR** writes `/etc/sysctl.d/99-bbr.conf`. Default qdisc and actual interface queues are distinct;
custom/multiqueue layouts are preserved. Only a recognized single default `pfifo_fast` root is eligible for replacement.

**TCP tuning** writes `/etc/sysctl.d/99-onevps-tune.conf`, raises TCP buffer ceilings while preserving validated
minimum/initial values, and adjusts Fast Open, MTU probing, backlog and ephemeral ports. Shared socket settings
may also affect non-TCP traffic. It does not create swap or tune journald/conntrack. No default UDP/443 block is added.
There is no guaranteed speedup; failed sysctl application can be partial and is not atomically rolled back.

## Verification and contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for syntax, ShellCheck, unit, Markdown and real-core checks using
`tests/test_singbox.sh`, which invokes `tests/runtime_singbox.py` using only the Python 3 standard library.
Runtime tests use short-lived loopback processes, not host services.

The macOS arm64 run with **sing-box v1.14.3** passed 11 outbound configuration checks and local runtime tests for
Hysteria 2 TCP/UDP forwarding, wrong-password rejection, `auth_user`-based layered routing, private-CIDR rejection,
and a real VLESS REALITY Vision handshake/TCP forwarding against a local TLS 1.3 target.
These results cover same-core local tests, not production readiness, other client implementations.
Generated configuration `check` alone is not connectivity proof. Cross-client interoperability and host-level
failure-path testing remain follow-up work on disposable hosts; record exact environments and results.

Report bugs with sanitized environment details and exact versions. Report vulnerabilities privately via
[SECURITY.md](SECURITY.md), never by publishing credentials or raw production logs.

## License and responsibility

[MIT License](LICENSE). Use only on systems and networks you are authorized to administer, comply with applicable
law and provider terms, and review downloads and host changes before execution.
