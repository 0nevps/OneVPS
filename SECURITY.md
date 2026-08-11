# Security Policy

[中文说明](#中文说明)

## Supported Versions

Security fixes target the latest release and the current `main` branch. Historical releases, historical commits,
and locally modified copies are not maintained as separate supported versions.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Current `main` | Development |
| Historical releases and commits | No |
| Third-party forks | No |

## Reporting a Vulnerability

Use GitHub Private Vulnerability Reporting:

[Report a vulnerability privately](https://github.com/0nevps/OneVPS/security/advisories/new)

Do not open a public issue for a suspected vulnerability. Repository administrators should keep Private
Vulnerability Reporting enabled so the link above remains available.

Include as much of the following as possible:

- A description of the issue and its security impact
- The affected OneVPS commit
- Reproduction steps or a minimal proof of concept
- The affected distribution, architecture, Xray version, and Caddy version
- Whether default configuration is affected
- Suggested mitigations or fixes, if known

Redact all live credentials and identifying infrastructure data. Do not submit working node URLs, UUIDs,
passwords, private keys, WebSocket paths, API tokens, or unnecessary public IP addresses.

## Response Process

Maintainers aim to acknowledge a complete report within seven days. Investigation and remediation time depends
on impact, reproducibility, and whether coordination with Xray, Caddy, a Linux distribution, or another upstream
project is required.

The expected process is:

1. Confirm receipt and establish a private communication thread.
2. Reproduce and assess severity and affected configurations.
3. Develop and validate a fix or mitigation.
4. Coordinate upstream reporting when the root cause is outside OneVPS.
5. Publish the fix and a security advisory when disclosure is appropriate.

Please allow time for a fix before public disclosure. Credit will be given when requested, unless legal or privacy
constraints prevent it.

## Scope

In scope:

- The `onevps.sh` code in this repository
- Generated Xray and Caddy configuration
- Credential generation, storage permissions, and share-link handling
- Installation, update, service, firewall, and system-tuning operations performed by OneVPS

Usually out of scope unless OneVPS causes or worsens the issue:

- Vulnerabilities in Xray-core, Caddy, Linux, systemd, or package repositories
- Compromised hosts unrelated to OneVPS behavior
- Social engineering, denial-of-service traffic, or attacks against infrastructure not owned by the reporter
- Reports that expose third-party credentials or personal data

## 中文说明

- 安全漏洞请通过
  [GitHub Private Vulnerability Reporting](https://github.com/0nevps/OneVPS/security/advisories/new) 私密提交，
  不要创建公开 issue。
- 仓库管理员需要在 GitHub Security 设置中保持 Private Vulnerability Reporting 开启。
- 报告应包含影响、受影响 commit、复现步骤、环境版本和已知缓解方式。
- 必须删除节点链接、UUID、密码、私钥、WebSocket 路径、令牌及不必要的公网 IP。
- 当前维护最新正式版本与 `main` 分支；历史版本、本地修改版本和第三方 fork 不单独提供安全支持。
