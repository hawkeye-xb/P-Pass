# macOS runner 全仓统一 macos-26

- 状态：已采纳
- 日期：2026-11-06
- 采纳：产品负责人 2026-11-06 定「追新不追旧」
- 关联：#1474、#1475（临时换 macos-15）、#1477（按本方案实现）、#1478

## 结论

1. 全仓所有 macOS CI / 发布 job 统一用 `runs-on: macos-26`，不再按 job 各选版本。
2. 具体三处（由 #1477 实现）：
   - `.github/workflows/release.yml` 的 macOS 构建 job（约 266 行，现为 `macos-14`）；
   - `.github/workflows/ci-rust.yml` 的 `test-platform-macos`（现为 `macos-15`，#1475 临时值）；
   - `.github/workflows/artifacts.yml` 的 `macos-arm64-bin`（现为 `macos-15`，#1475 临时值）。
3. 改动处的注释引用本文件，说明「追新不追旧」。

## 背景

2026-11-06 GitHub 停用 `macos-14` runner。#1474 / #1475 把 ci-rust 与 artifacts 临时换成
`macos-15` 先让 CI 恢复，但 `release.yml` 的 macOS 构建仍是 `macos-14`，下次发版会失败。
`release.yml` 属核心路径，须先有已采纳方案才能改，故先定本方案。

## 依据

- 产品负责人 2026-11-06「追新不追旧」：runner 跟最新走，不守旧版本。
- iOS job 已在 `macos-26` 上构建、签名并上传 TestFlight（v2026.11.1），`macos-26` 的签名与上传链路已有实证。

## 风险与验证

- 风险：Xcode / SDK 版本跨度较大，可能影响 Tauri 打包、dmg 制作、代码签名与公证。
- 验证：
  - PR 上 `test (platform, macos)` 在 `macos-26` 实跑 success（E3）。
  - dmg 签名公证要到下一个 test 包才能验：对产物跑 `codesign --verify`、`spctl`、`stapler validate`，
    并核对 `app.tar.gz` 的更新签名。未验之前不发正式版。

## 备选

- 统一 `macos-15`：不选。它比 `macos-26` 更早被停用，等于把同样的问题推迟，下一次又要改。
- 各 job 各自选版本：不选。版本分散，每次停用都要逐处排查，也无法保证 CI 与发布环境一致。
