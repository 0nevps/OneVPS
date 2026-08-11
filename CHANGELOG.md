# Changelog

All notable changes to OneVPS are documented in this file. The project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-11

### Added

- VLESS TCP REALITY nodes with XTLS Vision, uTLS share links, X25519 keys, and automatic target selection.
- Trojan WebSocket nodes behind Caddy with loopback-only Xray inbounds and managed secret routes.
- Node lifecycle operations for credentials, ports, domains, routes, enabled state, and share links.
- Xray configuration generation with validation, restricted private-network and BitTorrent routing, and optional
  UDP/443 blocking.
- Least-privilege systemd service generation, BBR support, optional system tuning, and uninstall workflows.
- English and Chinese operator documentation, an MIT license, contribution guidance, and a security policy.
- GitHub Private Vulnerability Reporting, issue forms, and a pull request template.
- Continuous integration for Bash syntax, ShellCheck, Markdownlint, and 26 dependency-light configuration tests.

### Changed

- Domain normalization now uses portable character conversion and also works with Bash 3.2.
- Release installation documentation now uses versioned assets with SHA-256 verification.

### Security

- Generated credentials use cryptographically secure tools and are stored with restricted file permissions.
- Xray runs without root privileges and Trojan inbounds listen on loopback only.
- Runtime configuration is validated before activation, and failed Caddy route updates are rolled back.

[Unreleased]: https://github.com/0nevps/OneVPS/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/0nevps/OneVPS/releases/tag/v0.1.0
