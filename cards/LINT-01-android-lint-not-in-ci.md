# LINT-01 Android lint 不在 CI 里跑，已知一处红长期无人看见　级别 L3

> ⬜ 状态：未开工
> 级别：L3 · 阻塞：无

## 问题

`ci-android.yml` 只跑单测 + `assembleDebug`，**不跑 `lint`**。于是 lint 的
结论没有任何门禁，红了也没人知道。

已知的一处：`BucketScreen.kt` 的 `BucketCoverImage` 里 `produceState` 报
`ProduceStateDoesNotAssignValue`——因为 `value` 的赋值裹在
`if (value == null && coverUri != null)` 里，lint 的检查器看不出条件分支里
有赋值，属于**误报**（缓存命中时本来就不该重新赋值）。

问题不是这一条误报，而是**没有门禁 = 下一条真报也会被埋掉**。MOB-08 那轮
就吃过一次类似的亏（`NewApi` 红一直没人看见）。

## 期望行为

Android lint 在 CI 里有结论。误报用 `@Suppress` / `lint.xml` 显式豁免并写
理由，真报当场修——不允许「一片红所以谁也不看」的状态继续。

## 验收标准

- [ ] `ci-android.yml` 增加 lint step，`lintDebug`（或等价 task）零告警才算绿
- [ ] `BucketScreen.kt` 那条误报显式豁免（带一行注释说明为什么是误报），
  或改写成 lint 认得的形式
- [ ] 反证：故意引入一条新 lint 违规 → CI 变红
- [ ] 首次开门禁时把现存告警清空（清不完的列进 `lint.xml` baseline 并在卡里
  逐条记原因，不许无声 baseline 全量吞掉）

## 范围

- 只准动：`.github/workflows/ci-android.yml`、`apps/android/**` 的 lint 配置
  与被 lint 点名的文件
- 不准动：业务逻辑（本卡只管 lint 门禁与豁免，不顺手重构组件）

## 阻塞与依赖

无。注意 CI-01 的额度纪律：lint 挂在既有 ci-android job 里，不新开 workflow。

---

## 备注

来源：`docs/NEXT.md`「未开卡」清单（`BucketScreen.kt:81` lint 红，CI 不跑
lint 所以一直没暴露），2026-08-25 按模板开卡。

首次开门禁大概率会顶出一批存量告警——预期工作量主要在这里，不在那一条误报。
