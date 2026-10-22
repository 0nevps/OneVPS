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
- `jq` and OpenSSL
- Python 3 with its standard library for `tests/runtime_singbox.py` (no third-party Python packages)
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
- Target pinned sing-box v1.14.3; validate generated sing-box and Caddy configuration before activation.
- Preserve rollback behavior and fail closed on legacy configuration, schema or service conflicts.
- This is a fresh-install rewrite, not a migration or dual-core implementation. Metadata uses `schema_version: 1`.
- Avoid unrelated formatting or refactoring in a focused fix.
- Existing commits use Conventional Commit-style subjects such as `fix(caddy): ...`; matching that style is
  encouraged.

## Required Checks

The sing-box rewrite and its CI checks are being implemented together. The required check set is:

```bash
bash -n onevps.sh tests/test_onevps.sh tests/test_singbox.sh
shellcheck --severity=warning onevps.sh tests/test_onevps.sh tests/test_singbox.sh
bash tests/test_onevps.sh
python3 -I -c 'import ast, pathlib; ast.parse(pathlib.Path("tests/runtime_singbox.py").read_text())'
SINGBOX_TEST_BIN=/absolute/path/to/onevps-sing-box bash tests/test_singbox.sh
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

`tests/test_singbox.sh` replaces the former Xray outbound check. Use a real, checksum-verified **v1.14.3**
binary; a missing binary or incorrect version must fail rather than silently skip validation.
The shell test invokes `tests/runtime_singbox.py` automatically. Its standard-library harness starts short-lived
core/server processes bound to loopback, cleans them up, and does not modify host services. Run it from the
repository, with Python 3 and OpenSSL available; no production configuration or credentials are needed.

The macOS arm64 run with sing-box v1.14.3 passed 11 outbound `check` cases, Trojan WS TCP/UDP forwarding,
wrong-password rejection, `auth_user`-based layered routing, private-CIDR rejection, and VLESS REALITY Vision
handshake/TCP forwarding using a local TLS 1.3 target. This is same-core local validation, not production,
cross-client or Caddy integration validation.

Test priorities:

- Real-core `check` for generated Reality/Vision, Trojan WS and every supported outbound configuration.
- Node-local authentication, default clients, user/node/direct routing precedence and safety blocks.
- Rejection of `spx`, gRPC `multi`, XHTTP, malformed links and unsupported metadata schemas.
- Download/checksum failures, old-installation conflicts, validation failures and activation rollback.
- Local same-core runtime regression tests for handshakes, authenticated TCP/UDP, expected exits and safety blocks.
- Follow-up cross-client/Caddy interoperability and host-level tests: revoked users, Caddy WS forwarding,
  service rollback and upstream failure without direct fallback.
- Trojan inbound WS paths must match `^/[A-Za-z0-9/_-]*$`; reject spaces, query strings and fragments without
  applying this inbound-only restriction to supported outbound WS link paths.

Configuration acceptance is not proof of interoperability or production readiness. Record which scenarios were
actually executed, with exact core/client versions; clearly separate pending tests from successful results.

When changing `.github/workflows/*.yml`, also run:

```bash
actionlint
```

Runtime testing changes system services and files. Perform manual installation or upgrade testing only on a
disposable VPS or virtual machine that you are authorized to modify. Record the distribution, version,
architecture, package manager, sing-box version, and Caddy version used for the test.
Use fresh installations for the rewrite; do not test it by importing or overwriting an existing Xray deployment.

## Releases

Push an existing stable version tag such as `v0.1.2` to trigger the Release workflow. It validates the tagged
commit with the same checks as CI, then publishes `onevps.sh` and `SHA256SUMS` with generated release notes.
Only the publishing job has permission to write releases.

To backfill an existing tag, run the Release workflow from `main` and supply the tag:

```bash
gh workflow run release.yml --ref main -f tag=v0.1.2
```

The workflow must already exist on the default branch. Manual dispatch requires repository Actions write
access. Do not move or recreate published tags. Repeated runs verify existing assets without replacing them;
incomplete or conflicting releases fail for manual inspection. Historical backfills do not replace a newer
version as Latest. New releases remain drafts until both uploaded assets have been verified.

## Reporting Bugs

Include:

1. The OneVPS commit or script download date.
2. Distribution, release, architecture, package manager, and systemd version.
3. The menu action and expected result.
4. The actual result and minimal reproduction steps.
5. Sanitized logs or command output.

Do not report an upstream sing-box or Caddy defect as a OneVPS defect unless the integration or generated
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

- 推送 `v0.1.2` 格式的稳定版本 tag 后，Release workflow 验证该提交并自动发布脚本和校验文件。
- 补发已有 tag 时，从 `main` 手动运行 Release，输入 tag；需要仓库 Actions 写权限，workflow 必须已在默认分支。
- 不移动或重建已发布 tag；重复运行只验证已有资产，不覆盖文件。不完整或冲突的 Release 需人工检查。
- 上传资产验证成功前保持草稿；补发旧版本不会替换较新版本的 Latest 标记。
- 提交前先检索现有 issue；安全漏洞请按 [SECURITY.md](SECURITY.md) 私密报告。
- 公开内容中不得包含节点链接、UUID、密码、私钥、WebSocket 路径或未脱敏日志。
- 当前 `main` 正在实现固定 sing-box v1.14.3 的全新安装方案，不提供迁移或双内核；元数据为 `schema_version: 1`。
- 功能变更需同步更新中英文 README，并执行 Bash 语法、ShellCheck、自动测试和 Markdownlint。
- `tests/test_singbox.sh` 替代旧 Xray 出站检查；使用 `SINGBOX_TEST_BIN` 指定真实 v1.14.3 二进制，缺失不得跳过。
- 重点验证真实内核 `check`、用户与分层出口、拒绝不支持参数、旧安装冲突、下载校验和失败回滚。
- 运行验证由 shell 测试调用 `tests/runtime_singbox.py`，仅需 Python 3 标准库，使用 loopback 短命进程，不操作宿主服务。
- macOS arm64 / sing-box v1.14.3 已通过 11 种出站 check、Trojan WS TCP/UDP、错误密码拒绝、分层路由与私网拒绝，
  以及本地 TLS 1.3 目标上的 Reality Vision 实际握手及 TCP 转发。
- 上述同内核本地结果不代表生产验证；跨客户端、Caddy WS、访问撤销及主机级失败路径仍需后续验证。
- Trojan 入站 WS 路径限定 `^/[A-Za-z0-9/_-]*$`，拒绝空格、query 和 fragment；不混同出站 WS 路径规则。
- CI 与功能正在并行实施，未执行的测试不得写成已通过。
- 涉及安装、升级或系统配置的手工测试只能在有权管理的临时 VPS 或虚拟机中进行。
- Pull request 应说明问题、实现理由、验证结果、兼容性影响和回滚方式。
