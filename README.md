# OneVPS

[![CI](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml/badge.svg)](https://github.com/0nevps/OneVPS/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[简体中文](README_CN.md)

OneVPS uses [`onevps-singbox.sh`](onevps-singbox.sh) as its primary deployment and maintenance entry point
for sing-box nodes on Linux VPS hosts. This Bash-launched Python 3 script handles core installation,
nodes, users, outbounds, Caddy certificates, Realm relays, and service diagnostics. The original
[`onevps.sh`](onevps.sh) (Xray) remains in this repository, but does not share sing-box node state.

> **Read the script before running it.** It installs packages and modifies systemd services, Caddy
> configuration, and host firewall rules as root; optional actions change global kernel settings.
> Try it on a recoverable VPS first. Share links and configuration files contain credentials.

## Quick start

Requires Linux with systemd, root access, and Python >= 3.8. If Python 3 is missing, the launcher tries
apt, dnf, yum, or zypper; core installation also checks for `curl`, `openssl`, and `ss`. Download from `main`
to a **regular file**, inspect it, then run:

```bash
curl -fLO https://raw.githubusercontent.com/0nevps/OneVPS/main/onevps-singbox.sh
less onevps-singbox.sh
sudo bash onevps-singbox.sh
```

This URL tracks `main`, not an immutable release. First choose `1` to install/update sing-box (>= 1.14.0),
then `2` to add a node and retrieve its share link. Prepare DNS and cloud security-group rules for the
chosen node, then verify connectivity with a client from another network. **Do not use `bash <(curl ...)`:**
the certificate-sync timer and script updater must read a saved script file.

The current Release workflow still publishes only the Xray `onevps.sh` and `SHA256SUMS`; that checksum
**does not apply** to this sing-box download from `main`. Current CI also does not run the sing-box offline
self-test; maintainers should run the checks below separately.

## Choose a node

Select `2` from the main menu to add a node; `2 → 8` manages existing nodes/users and `2 → 9` displays links.

| `2` submenu | Node | Network and prerequisites |
| --- | --- | --- |
| `1` | VLESS + REALITY + Vision | TCP; no domain/certificate; tries port 443 by default |
| `2` | Trojan + WS + Caddy | TCP 80/443; domain points at VPS; Caddy terminates TLS |
| `3` | VMess AEAD + WS + Caddy | TCP 80/443; domain points at VPS; Caddy terminates TLS |
| `4` | Hysteria2 + TLS | UDP; domain and Caddy certificate; default port 24443 |
| `5` | Snell v5 (Surge) | TCP; sing-box does not implement Snell v5 QUIC Proxy Mode |
| `6` | Snell v6 (Surge) | TCP; requires a compatible Surge client |
| `7` | Shadowsocks 2022 (Surge) | TCP + UDP; `2022-blake3-aes-128-gcm` |

WS inbounds listen only on `127.0.0.1`; Caddy forwards a hidden path. Other site requests receive a
customizable 403 page. Hysteria2 listens on UDP; Caddy issues its certificate and a timer synchronizes it
to sing-box. The script attempts to open rules in active `ufw`/`firewalld`, but **you must also open the
appropriate port/protocol in your provider's security group**. BBR/TCP tuning is not UDP/QUIC tuning.

Single-user Snell v5/v6 outputs a Surge `[Proxy]` entry. Since Surge has no documented Snell multi-user
`userkey` policy syntax, multi-user output is a sing-box client outbound JSON instead. Shadowsocks 2022
outputs both `ss://` and Surge formats. Entering multi-user mode may change the default user's link;
the script asks for confirmation first.

## Operate and maintain

```text
1) Install / update sing-box (stable >=1.14)
2) Nodes / users / outbound / share links
3) Caddy TLS certificate management
4) Realm relay
5) Service / BBR / TCP tuning
6) Update script
7) Diagnostics
8) VPS-local acceptance checks
9) Uninstall managed sing-box
0) Exit
```

- **Nodes and users:** Under `2 → 8`, choose a node, then `1` to change its port, `2` to reset its default
  credential, `3` for users, `4` for outbounds, `5` to enable/disable, `6` to delete, or `7` for links.
  REALITY nodes also expose key/target operations; WS nodes expose domain/path/Caddy-route operations.
  Resetting credentials invalidates old links.
- **Outbounds:** For all users or selected users, choose inherited settings, explicit direct, or one proxy
  link. The script accepts subsets of `ss://`, `socks5://`, `vless://`, `vmess://` (v2 Base64 JSON), and
  `snell://`. All-user changes clear individual overrides. Safety blocks precede user overrides, node
  outbounds, and default direct access. Proxy failure does not fall back to direct. Pasted links and
  persisted configuration may contain secrets.
- **Certificates:** Menu `3` requests certificates, lists expiry, syncs now, and shows Caddy/timer status.
  Point DNS at the VPS and allow TCP 80/443. The sync timer runs every five minutes. Do not reuse a domain
  already owned by another site.
- **Relay and network:** Menu `4` manages a separate Realm TCP or TCP+UDP relay; Realm adds no authentication
  or encryption. Menu `5` restarts/checks the service, shows logs, or optionally applies global BBR/TCP tuning.
- **Script update:** Menu `6` downloads from `main`, checks Bash syntax, prints SHA-256, and asks for approval
  before replacing the saved script and installed maintenance copy. Restart the menu to use the new script.
  Updating the script does not update the sing-box core.
- **Uninstall:** Menu `9` removes managed nodes, configuration, service, and certificate-sync timer, with
  an optional core-package removal. It preserves Caddy, Realm, and sysctl settings; cloud firewall rules
  remain your responsibility.

Node configuration is checked by sing-box before activation. The script restarts the service and checks
listeners; on detected failure, it attempts to restore metadata, configuration, Caddy routes, and service
state. Make your own backup before changes; this rollback is not protection against power loss.

## Verify and troubleshoot

Run on the VPS. `--check` and `--acceptance` require root and inspect local configuration, services, sockets,
and certificates; they are not pure parse-only checks:

```bash
sudo bash onevps-singbox.sh --version
sudo bash onevps-singbox.sh --check
sudo bash onevps-singbox.sh --acceptance
systemctl status onevps-singbox.service
journalctl -u onevps-singbox.service -n 50 --no-pager
```

`--check` inspects core/service/configuration and expected listeners. `--acceptance` additionally tests
Caddy sites, certificates, and Realm (if configured), returning nonzero on failure. **Neither proves**
public DNS, cloud security-group access, remote client handshakes, UDP/QUIC traffic, or real ACME renewal;
verify from an independent network. If TLS issuance is pending, check DNS and TCP 80/443, then retry
certificate sync from menu `3` and inspect Caddy status.

| Location | Purpose |
| --- | --- |
| `/etc/onevps-singbox/nodes.json` | Node metadata and credentials |
| `/etc/onevps-singbox/config.json` | Generated sing-box configuration |
| `/etc/onevps-singbox/certs/` | Certificates synchronized for sing-box |
| `/etc/caddy/onevps-singbox.caddy` | Managed Caddy domain snippet |
| `/var/lib/onevps/sites/<domain>/index.html` | Customizable 403 page |
| `/etc/systemd/system/onevps-singbox.service` | sing-box service |
| `/etc/systemd/system/onevps-singbox-certs.timer` | Certificate-sync timer |
| `/usr/local/sbin/onevps-singbox` | Script copy used by the timer |

Protect files, backups, and links containing credentials. Never post them or unredacted logs in public issues.

## Maintenance and testing

When changing the script or documentation, use the actual behavior of
[`onevps-singbox.sh`](onevps-singbox.sh) as the source of truth, keep both READMEs aligned, and run the
local offline checks:

```bash
bash -n onevps-singbox.sh
bash onevps-singbox.sh --self-test
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

`--self-test` needs neither root nor public network and exercises configuration generation, links, and
rollback on Linux. Some tests need local `openssl` and assume Linux users/architecture. It does not replace
real client, Caddy/certificate, and
cross-distribution testing on a disposable VPS with sing-box >= 1.14.0. Existing CI and release publishing
still target the Xray script; run these checks separately and record host-level verification.

## Legacy Xray script

[`onevps.sh`](onevps.sh) uses Xray-core with a separate `xray.service` and
`/usr/local/etc/xray/` configuration. The menus, parameters, and paths in this README do not apply to it.
Neither script automatically imports, migrates, or cleans up the other's nodes; do not treat them as one
configuration manager. Current releases contain only the Xray script and its matching checksum; see the
[contributing guide](CONTRIBUTING.md) and [changelog](CHANGELOG.md) for Xray maintenance and tests.

Report suspected vulnerabilities privately via [SECURITY.md](SECURITY.md). Use OneVPS lawfully only on
systems and networks you are authorized to manage; you are responsible for reviewing the script, complying
with applicable laws and provider policies, and protecting credentials. Licensed under [MIT](LICENSE).
