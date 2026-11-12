# 两个 Release run 重叠：test 发布按 test-channel 全局串行排队

- 状态：已采纳
- 日期：2026-11-12
- 采纳：产品负责人 2026-11-12 拍板方案 B（按 test-channel 全局串行，排队不取消）
- 关联：#1556、#1546、docs/decisions/2026-11-06-release-test-channel-single-writer.md

## 背景

`test-channel` 是唯一的滚动通道，所有 test 发布都往它写。收敛入口 `cleanup-test-channel.sh` 会删除「比被指向的最新版本还旧、且没有任何清单指向」的 test 草稿与 tag。现有收敛只保证「同一个 Release run 内单点、串行、幂等」，跨 run 没有覆盖：两个 Release run 重叠时，一个 run 的收敛可能把另一个 run 正在用的旧 tag / 草稿当「没人指向」删掉。

`release.yml` 当前没有 workflow 级 `concurrency`，所以两个 run 谁都不让谁。

## 决定

在 `release.yml` 加 workflow 级 `concurrency`：test 发布（tag 含 `-test.`）按固定 key `test-channel` 分组串行，`cancel-in-progress: false`（新 run 排队等待，不取消正在跑的 run）。正式版（stable tag）不碰 test-channel，不用这个 key，不受影响。

## 理由

**本质要保证什么**：`test-channel` 及其引用的整批 test 草稿/tag 是「单写者共享资源」，同一时刻只该有一个 writer 在动它——收敛删掉的，绝不能是另一个仍在进行的 run 还要用的东西。

**标准做法**：给共享资源加互斥，让写入方排队。GitHub Actions 的标准做法就是 workflow 级 `concurrency` 按资源分组 + 排队（`cancel-in-progress: false`）。

**分组粒度为什么按 test-channel 而不是按 tag**：`cleanup-test-channel.sh` 删的是「任意旧的 test 草稿/tag」，跨 tag。按 tag 分组只防「同一 tag 重复触发」，两个不同 tag 的 run 并行时仍会互相误删——不变量不成立。按 test-channel 全局串行才从根上消除。test 发布本来就没有「同时发两个版本」的需求（用户一次只测一个），全局串行没有损失。

## 后果

- 两个 test 发布 run 重叠时，后触发的排队等前一个完整跑完（含收敛）才开始，跨 run 误删从根上消除。
- `cancel-in-progress: false`：排队不取消，正在跑的 run 不被新 run 打断。
- 正式版发布不排队、不受影响；test 与正式版之间也不互相阻塞（不同 concurrency key）。
- 验收（照卡 #1556）：构造两个 test run 重叠，后一个必须排队等待前一个收完；构造 test 与 stable 同时触发，两者互不阻塞。

## 备选

- **按 tag 分组**（同一 tag 串行、不同 tag 并行）：只防最常见「同一 tag 重复触发」，跨 tag 误删的洞仍在。不取。
- **`cancel-in-progress: true`**：会让新 run 取消正在跑的旧 run，正是要避免的。不取。
