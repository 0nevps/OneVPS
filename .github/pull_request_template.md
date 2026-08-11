# Pull Request

## Problem

Describe the concrete problem this pull request addresses.

## Approach

Explain the implementation and why it is preferable to simpler alternatives.

## Verification

List the automated and manual checks performed, including the distribution and architecture for host-level tests.

```text
bash -n onevps.sh tests/test_onevps.sh
shellcheck --severity=warning onevps.sh tests/test_onevps.sh
bash tests/test_onevps.sh
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

## Risk and Rollback

Describe compatibility, security, migration, credential, firewall, systemd, and rollback considerations.

## Checklist

- [ ] The change is focused and does not include unrelated formatting.
- [ ] Tests cover new or changed pure logic.
- [ ] Generated Xray or Caddy configuration is validated before activation.
- [ ] English and Chinese documentation are synchronized when behavior changes.
- [ ] Logs, fixtures, and screenshots contain no live credentials or identifying server data.
- [ ] Security-sensitive details use Private Vulnerability Reporting instead of this pull request.
