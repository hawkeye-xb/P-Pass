# Security Policy

[中文](SECURITY.zh.md)

## Reporting a vulnerability

Please report vulnerabilities **privately**. Do not open a public issue,
discussion or pull request for them.

1. Go to the repository's
   [Security → Report a vulnerability](https://github.com/hawkeye-xb/P-Pass/security/advisories/new) page.
2. Describe the problem, the affected platform and version, and the steps
   to reproduce it. A proof of concept helps, but is not required.

Only the maintainers can see the report.

## What happens next

- We reply to confirm that we received the report within **7 days**.
- We keep you updated in the same private report while we investigate and
  fix the problem.
- After a fix is released, we publish a
  [GitHub Security Advisory](https://github.com/hawkeye-xb/P-Pass/security/advisories)
  that describes the problem and the fixed versions. We credit you in the
  advisory unless you ask us not to.

## Supported versions

Security fixes go into the latest stable release of each platform (the
desktop app, Android and iOS). Test builds (versions with a `-test` suffix)
and older releases do not get fixes; please update to the latest release.

## Scope

The threat model, including what P-Pass protects against and what it
does not, is in [docs/security/threat-model.md](docs/security/threat-model.md).
