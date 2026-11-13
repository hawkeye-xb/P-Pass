# 架构决策记录（ADR）

改动核心（`.github/core-paths.txt` 圈住的身份、签名、协议、数据、更新链、门禁）之前，先在这里写一份
ADR，验收人拍板后再拆卡实现。代码注释里出现的 ADR-003、ADR-004、ADR-006 等编号出自早期设计文档，
不在本目录。产品层面的决策仍然记在 `docs/product/` 下。

## 索引

| 日期 | 决策 | 状态 |
|---|---|---|
| 2026-11-02 | [每台测试设备只有一个安装槽](2026-11-02-one-install-per-test-device.md) | 提议 |
| 2026-11-03 | [自动备份规则缓存的到期判据](2026-11-03-flow-rule-cache-sentinel.md) | 已采纳 |
| 2026-11-03 | [onboarding 闸门与「连过这台电脑」判据](2026-11-03-onboarding-gate.md) | 已采纳 |
| 2026-11-05 | [发布链 hdiutil 遇到「Resource busy」时退避重试](2026-11-05-release-hdiutil-busy-retry.md) | 已采纳 |
| 2026-11-06 | [macOS runner 全仓统一 macos-26](2026-11-06-macos-runner-26.md) | 已采纳 |
| 2026-11-06 | [发版闸接进 release.yml：按「[验收] <正式 tag>」找台账](2026-11-06-release-acceptance-gate.md) | 已采纳 |
| 2026-11-06 | [test 版本号自动补丁与发版路径惰性登记](2026-11-06-release-test-next-patch-and-inert-paths.md) | 已采纳 |
| 2026-11-06 | [test-channel：写入与收敛分权，收敛单点跑一次、失败只告警](2026-11-06-release-test-channel-single-writer.md) | 已采纳 |
| 2026-11-09 | [服务启停与自启纳入核心名单](2026-11-09-core-paths-service-lifecycle.md) | 已采纳 |
| 2026-11-09 | [Windows 服务形态：「启动后台服务」必须真的启动](2026-11-09-windows-service-start.md) | 已采纳 |
| 2026-11-10 | [CI 与发布链外部下载的韧性与缓存](2026-11-10-ci-download-resilience.md) | 已采纳 |
| 2026-11-12 | [升级 sqlx 0.9 修复 bundled SQLite 的 CVE](2026-11-12-sqlx-0.9-cve.md) | 已采纳 |
| 2026-11-12 | [发版不冻结合入：删掉「main 前进就拒绝」的守卫](2026-11-12-release-no-merge-freeze.md) | 已采纳 |
| 2026-11-12 | [两个 Release run 重叠：test 发布按 test-channel 全局串行排队](2026-11-12-release-test-channel-concurrency.md) | 已采纳 |
| 2026-11-13 | [本地授权目录作为照片和视频备份来源](2026-11-13-local-folder-media-source.md) | 已采纳 |
| 2026-11-13 | [Windows 普通 MP4 用独立视频 decoder（Media Foundation）生成真缩略图](2026-11-13-windows-video-decoder.md) | 已采纳 |

## 写法

文件名用 `YYYY-MM-DD-<slug>.md`，中文书写，先写结论再展开细节，控制在 300 行以内。每份 ADR
包含以下几节：

- **背景**：现状如何，遇到了什么问题（附 issue 号）。
- **决定**：具体怎么做，写到代码位置，能直接拆成卡。
- **理由**：这件事本质上要保证什么；业界的标准做法是什么，我们怎么对齐，哪里偏离、为什么偏离。
- **后果**：会带来哪些变化和代价，哪些东西不再被覆盖。
- **备选**：考虑过但没有采纳的方案，以及不采纳的原因。

状态分三种：提议、已采纳、已废弃。一份 ADR 被新的取代时，不删旧文件：把它的状态改成「已废弃」，
并链接到取代它的那一份。
