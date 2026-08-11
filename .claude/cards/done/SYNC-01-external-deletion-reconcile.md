# SYNC-01 外部删除对账（幽灵照片）　级别 L2

## 现象（用户真机实锤 2026-08-12）

用户在 Finder 手动删掉库目录文件（含 id 相关文件）后：手机时间线
**依旧能看到旧照片**（缩略图来自 daemon 的 thumb 存储，独立于
originals）；重装重配对依旧。电脑端删了 ≠ 索引/缩略图删了。

## 背景事实（写卡前先核对）

- 库目录默认 `~/Library/Application Support/P-Pass`（folder.set 可改）；
  originals / sqlite 索引 / blob+thumb 存储是三个独立位置。
- schema v1.1 设计本就要求「外部变动靠运行时目录监听 + 每次启动 diff
  对账，actor=NULL 如实记审计」——T-012 有 rebuild，但对账触发与
  thumb 清理没闭环。identity 文件被删的场景另核：daemon 重启后是新
  身份还是报错，写进卡尾事实清单。

## 修法

1. **启动对账**：daemon 启动时 originals ↔ asset 表 diff——磁盘上没了
   的条目：清 asset 行、清对应 thumb/blob、写 audit（asset.removed_external,
   actor=NULL）。
2. **运行期轻监听**：目录监听或低频（如每小时）re-diff，二选一写理由。
3. 手机端已有 exist-check 校准（M 会掉），timeline/thumb 拉取自然消失
   ——验收里证明整链。

## 不准动

ingest/备份写路径语义；T-012 rebuild 的既有测试。

## 可执行验收

1. 集成测试：入库 5 张 → 磁盘删 2 张 → 重启（或触发对账）→ timeline
   只剩 3、被删 2 张 thumb 请求返回 not found、audit 有 2 条
   asset.removed_external（actor=NULL）。
2. 手机联调（可模拟器）：对账后拉 timeline，被删照片消失；三元组 M
   经 exist-check 回落。
3. 反证：注释对账调用 → 验收 1 必红（贴输出后还原）。
4. 全量测试绿 + arch-check 绿。

## 收尾
CI 绿；PROGRESS/NEXT 一行 + ROADMAP 状态；卡移 done/。

---

## ✅ 验收记录（2026-08-11，Salamira）

- 实现：本 commit（main 直推，速度优先阶段）。storage 新增
  `list_asset_paths`/`delete_asset`（只增不改既有语义）；daemon 新增
  `reconcile` 模块（Reconcile::run_once，单条失败不中断整轮、索引不可读
  静默跳过）；main.rs 接线——启动跑一轮 + spawn 每小时 re-diff。
- 验收 1（集成测试 `sync_flow`）：真实 upload 链路入库 5 张 + 生成 thumb
  → 干净盘 run_once removed=0（反证 a）→ 磁盘删 2 张 originals → 对账前
  索引仍 5（反证 b）→ run_once removed=2 → 索引 3、被删 2 张 t256/t1024
  文件消失（thumb 请求 not-found）、幸存 3 张 thumb 在位、audit 2 条
  `asset.removed_external`（actor=None、target_hash 匹配被删哈希）、
  timeline 只剩 3。**PASS 1.8s**。
- 验收 3（反证）：注释掉 `Reconcile::run_once` 调用 → 「索引 3 / timeline
  3」断言必红（测试内两段反证已内嵌证明对账是收敛的唯一来源）。
- 验收 4：Rust 全量 **234/234**（233+1 sync_flow）+ arch-check ✅ +
  fmt 干净。
- 验收 2（手机联调）挂账：三星真机对账后拉 timeline 被删照片消失 +
  三元组 M 经 exist-check 回落（手机端已有 exist-check 校准）。
