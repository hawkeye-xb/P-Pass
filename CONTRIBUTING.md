# Contributing to P-Pass

[中文](CONTRIBUTING.zh.md)

Thanks for your interest in P-Pass. This page covers the rules every
contribution has to meet.

## Before you start

- **Bugs and feature ideas**: open an issue with one of the
  [issue templates](https://github.com/hawkeye-xb/P-Pass/issues/new/choose).
  Not sure it's a bug? Ask in
  [Discussions](https://github.com/hawkeye-xb/P-Pass/discussions/categories/q-a) first.
- **Security vulnerabilities**: do not open a public issue. Follow
  [SECURITY.md](SECURITY.md).
- **Code changes**: one change per branch and pull request. Fill in the
  [pull request template](.github/PULL_REQUEST_TEMPLATE.md).

## License of contributions

By contributing, you agree that your contribution is licensed under the
[AGPL-3.0](LICENSE), together with the
[App Store distribution exception](APP_STORE_EXCEPTION.md). You keep the
copyright of your contribution. We do not ask you to sign a Contributor
License Agreement (CLA).

## Sign off your commits (DCO)

Every commit must be signed off under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/).
Signing off means you certify that you wrote the change, or otherwise have
the right to submit it under the project's license.

Add the sign-off with `git commit -s`. It appends a line that must match
the commit author:

```
Signed-off-by: Your Name <you@example.com>
```

A CI check (`CI DCO`) fails on pull requests that contain commits without a
matching sign-off. To sign off commits already on your branch:

```bash
git rebase --signoff origin/main
git push --force-with-lease
```

## Project rules

- **Bilingual docs**: user- and contributor-facing documents ship in
  English with a Chinese sibling (`*.zh.md`), or as clearly-sectioned
  bilingual files for short READMEs. Internal engineering logs may be
  Chinese-first; commit messages are English.
- **Agent-first interfaces**: every feature must be drivable and
  verifiable through the testclient CLI / daemon IPC without a human —
  GUIs are skins over those interfaces.
- **Architecture gates**: `iroh` imports only in `transport`; platform
  `#[cfg]` only in `platform`; enforced by `tools/arch-check.sh` in CI.

## Code of conduct

Everyone taking part in this project is expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
