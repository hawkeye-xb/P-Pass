# Changelog

All notable changes to P-Pass are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Cross-ecosystem family photo center: Android → home computer encrypted
  auto-backup over iroh 1.0 P2P (direct connection with relay fallback).
- Desktop shell (macOS dmg): pairing QR, devices, resident daemon
  one-click hosting.
- Android app: camera-scan pairing, MediaStore backup pipeline, timeline
  browsing, video playback.
- Release pipeline: multi-platform assets (daemon self-contained zips,
  macOS dmg, signed Android APK) + SLSA attestation.
- i18n (en/zh), failure scenario automation, telemetry (self-hostable
  Analytics Engine intake).
- E2E live scenarios in CI (android hello/pair/backup, nightly + on
  release tags).
- Version/release norms (RELEASING.md) + one-shot version bump tool
  (tools/bump-version.sh, overwrite-guarded).
