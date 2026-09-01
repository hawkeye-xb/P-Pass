# ARCH-06 换 Desktop 时保留用户配置并隔离旧运行（L2）

> 🟡 状态：进行中（已认领，待先写 P-01/P-02 失败测试）
> 级别：L2 · 前置：ARCH-02、ARCH-03、ARCH-04、ARCH-05

## 问题

手机改配对 Desktop 后，旧 Desktop 的发现水位、队列、取消轮、partial 与迟到回执都不能继续影响新 Desktop；但用户已选相册和备份条件不是旧 Desktop 的运行状态，不应因改配对被清掉。

## 期望行为

将配对身份显式建模为持久 `pairingEpoch`。切换 Desktop 时，保留用户配置与范围事实，原子清除旧 epoch 的发现、队列、取消轮、lease 与 partial 归属；旧 Desktop 的迟到完成凭据不得确认新 epoch 的项。

本卡覆盖 Case Matrix：**P-01、P-02**。

## 验收标准

- [ ] 先写 `ARCH01PairingEpochTest`，执行
      `cd apps/android && ./gradlew :app:testDebugUnitTest --tests '*ARCH01PairingEpochTest'`
      → P-01/P-02 先按预期失败，再绿。
- [ ] P-01：切换 Desktop 后保留 ScopeRevision 与用户配置边界；旧 epoch 的 DiscoveryCursor、UploadCursor、items、CancellationRound、fetch lease 与 partial 均不可进入新 epoch。
- [ ] P-02：旧 Desktop 的迟到完成凭据不能改变新 epoch 的传输历史。
- [ ] 反证：保留旧队列/取消轮或接受旧 epoch 回执时，对应测试必须变红。
- [ ] 全量 Android JVM 单测通过，并报告本次生成 XML 的测试总数与 0 failures。

## 范围

- 只准动：ARCH-01 新账本的 `pairingEpoch`、换 Desktop 纯状态迁移、完成凭据的 epoch 校验及对应 JVM 单测。
- 不准动：旧 `PairingStore` / `MainActivity.clearLocalPairing` 实际接线、WorkManager 调度、UI、Daemon/proto、实际 native fetch adapter。
- 不准以现有 `clearLocalPairing()` 的旧状态文件清理替代新账本的 epoch 隔离。

## 阻塞与依赖

无。ARCH-02~05 已提供账本、严格消费者、完成凭据和取消轮事实；本卡只定义换 Desktop 的新账本边界。

---

## 实施记录

- 2026-09-01：认领。已核对旧 UI 的 `clearLocalPairing()` 会清 PairingStore、per-remote confirmed cache、水位、暂停态与 WorkManager，但它不表达 ARCH-01 新账本的配对 epoch；本卡先用 P-01/P-02 失败合同测试钉住该缺口。

## 备注

来源：ARCH-01 §4、§8 与 Case Matrix P-01/P-02。用户配置保留与旧运行事实清理是两个独立动作；不得通过清空所有本地偏好或复用旧 WorkManager 管线实现。