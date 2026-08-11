# Contributing to OneVPS

[中文说明](#中文说明)

Thank you for helping improve OneVPS. Contributions are most useful when they are focused, reproducible, and
safe to review.

## Before You Start

- Search existing issues before opening a new one.
- Use public issues only for non-sensitive bugs and feature requests.
- Follow [SECURITY.md](SECURITY.md) for suspected vulnerabilities.
- Never publish node URLs, UUIDs, passwords, private keys, WebSocket paths, access tokens, IP addresses that must
  remain private, or unredacted production logs.

## Development Setup

The repository intentionally has a small toolchain. For local checks, install:

- Bash
- [ShellCheck](https://www.shellcheck.net/)
- Node.js and npm for Markdownlint
- [actionlint](https://github.com/rhysd/actionlint) when changing GitHub Actions workflows

Clone the repository and create a topic branch:

```bash
git clone https://github.com/0nevps/OneVPS.git
cd OneVPS
git switch -c fix/short-description
```

## Making Changes

- Keep the script compatible with Bash; do not introduce shell-specific behavior from zsh or fish.
- Preserve `set -euo pipefail` behavior and quote variable expansions unless intentional splitting is required.
- Keep English and Chinese documentation synchronized when user-visible behavior changes.
- Make host-level operations explicit and idempotent where practical.
- Validate generated Xray or Caddy configuration before activation and preserve rollback behavior.
- Avoid unrelated formatting or refactoring in a focused fix.
- Existing commits use Conventional Commit-style subjects such as `fix(caddy): ...`; matching that style is
  encouraged.

## Required Checks

Run the same baseline checks as CI:

```bash
bash -n onevps.sh
shellcheck --severity=warning onevps.sh
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

When changing `.github/workflows/*.yml`, also run:

```bash
actionlint
```

Runtime testing changes system services and files. Perform manual installation or upgrade testing only on a
disposable VPS or virtual machine that you are authorized to modify. Record the distribution, version,
architecture, package manager, Xray version, and Caddy version used for the test.

## Reporting Bugs

Include:

1. The OneVPS commit or script download date.
2. Distribution, release, architecture, package manager, and systemd version.
3. The menu action and expected result.
4. The actual result and minimal reproduction steps.
5. Sanitized logs or command output.

Do not report an upstream Xray or Caddy defect as a OneVPS defect unless the integration or generated
configuration is involved. Link the upstream issue when one exists.

## Pull Requests

A pull request should:

- Explain the problem and why the proposed approach is appropriate.
- Keep the diff limited to that problem.
- Describe automated and manual verification.
- Update both READMEs when behavior or operator guidance changes.
- Pass all required checks.
- Call out compatibility, security, migration, and rollback considerations.

Maintainers may ask for a smaller change or additional evidence when a patch affects root-level operations,
firewall rules, Caddy routing, generated credentials, or systemd hardening.

## 中文说明

- 提交前先检索现有 issue；安全漏洞请按 [SECURITY.md](SECURITY.md) 私密报告。
- 公开内容中不得包含节点链接、UUID、密码、私钥、WebSocket 路径或未脱敏日志。
- 功能变更需同步更新中英文 README，并执行 Bash 语法、ShellCheck 和 Markdownlint。
- 涉及安装、升级或系统配置的手工测试只能在有权管理的临时 VPS 或虚拟机中进行。
- Pull request 应说明问题、实现理由、验证结果、兼容性影响和回滚方式。
