# FIX-SC2 blobs_resume 300s 超时 flake 根治　级别 L1

## blocker（2026-08-10 第三次撞上，每次都要 rerun 碰运气）

`transport::blobs_resume::kill_mid_transfer_then_resume_verifies` 在
pr.yml lint+test job 里 300s TIMEOUT（nextest 默认每测试 300s 上限）。
历史：NEXT.md DAE-02 段记过 1 次（「隔离复跑 6.4s 过=并发偶发」），
2026-08-10 同一天连续 2 次（run 31351715951 / 31353615430，均为
`TIMEOUT [300.007s] (N/N) transport::blobs_resume`，rerun 后 5m21s
整体通过）。**第 3 次了，不能继续靠 rerun 碰运气**——CI 稳定性是
「CI 绿不过夜」底线的支撑，连续撞说明不是纯随机：50MB 传输 +
abort + 新 endpoint 重开 store + pull 补完，在 CI 慢 runner 上
可能逼近 300s，或被 nextest 默认线程数拖慢（T-021 原卡验收是
`--test-threads 1` 连跑 5 次零 flake，CI 是并行跑）。

## 修法（可选其一，选前在卡尾写理由）

1. 该测试加 `#[nextest(timeout = 600)]` 或 nextest 配置里对该测试
   单独放宽——最小改动，先看是不是真慢（贴慢 runner 实际耗时）。
2. 测试数据降档：50MB → 16MB（T-021 验收时 8MiB 已能钉死续传语义，
   50MB 是「大文件」余量，CI 上不值 300s 风险）——先量化耗时再降。
3. pr.yml lint+test job 用 `--test-threads 1` 跑 transport 包或该
   测试（T-021 原卡就是这么验收的，最接近「零 flake」的已知配置）。

## 可执行验收

1. 修完连续 3 次 CI run 的 lint+test job 全绿（不再 TIMEOUT）。
2. 本地 `cargo nextest run -p transport --retries 0 --test-threads 1`
   连跑 5 次零 flake（T-021 原验收命令，回归不破）。

## 反证

把超时上限改回 300s / 数据档调回 50MB → 慢 runner 上必复现 TIMEOUT
（贴输出后还原）。

## 证据要求

慢 runner 上该测试的实际 wall time（`--report-time` 或 nextest
timing）+ 3 次 CI 绿 run 链接。

## 收尾

直推 main 前确认 CI 绿；PROGRESS/NEXT 各留一行；卡移 done/ 并附验收记录。
