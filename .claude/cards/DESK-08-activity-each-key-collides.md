# DESK-08 活动流用时间戳当 key，同毫秒的审计撞键把整块打挂　级别 L1

> 🟡 已合并，等真机确认。**是 WATCH-02 的修复直接暴露出来的。**

## 现场（2026-08-21 用户真机，控制台刷屏）

```
Svelte error: each_key_duplicate
Keyed each block has duplicate key `1787292449250:asset.removed_external`
  at indexes 4 and 5
    in card.svelte / App.svelte
```

`1787292449250` = 14:07:29。用户在 Finder 里一次删了 5 张照片 → WATCH-02 的
局部对账把 5 条 `asset.removed_external` **写在同一毫秒**。

`App.svelte` 的活动流：

```svelte
{#each visibleAudit as e (e.ts + ":" + e.action)}    <!-- 旧代码 -->
```

5 条的 `ts` 和 `action` 全一样 → key 撞 → Svelte 抛错，**整个活动流渲染不出来**。

## 根因一句话

**时间戳不是身份，主键才是。**

`audit_log` 有自增主键，`storage::AuditRecord` 也一直带着 `id` 字段——只是
`ipc.rs` 的 `audit.list` 没往外传，前端拿不到，只能用 `ts + action` 凑一个
"看起来够独特"的 key。这个凑法在**批量对账**面前立刻破产。

⚠️ 这个 bug 一直躺在那儿，是 WATCH-02 把它踩响的：在 WATCH-02 修好之前，
整棵子树删除对账**一行都查不出来**（`LIKE 'originals//%'` 命中 0 行），所以
从来不会有 N 条同毫秒的删除审计。**修好一个 bug 会让下游的 bug 第一次有机会
发生**——这条值得记住。

## 改动

- `crates/daemon/src/ipc.rs`：`audit.list` 每行加 `"id": r.id`
- `apps/desktop/src/App.svelte`：
  - 两处 `{#each visibleAudit …}` 的 key → `e.id`
  - `backupDuration` 查表的 key 也从 `ts + ":" + actor` 换成 `e.id`
    （同形的撞键风险：同设备同毫秒两次 `backup.finished`，概率低但没必要留）

## 「还有几个同形的」——按 E2E-02 的教训查过了

`App.svelte` 全文只有 **3 处 keyed each**：

| 位置 | key | 唯一性 |
|---|---|---|
| `visibleAudit` ×2 | `e.id` | audit_log 主键 ✅ |
| `photoGroups` | `g.key` | 按月分组，构造上唯一 ✅ |
| `g.items` | `item.hash` | asset 主键 ✅ |

其余 5 处是无 key 的 `#each`，不可能抛 `each_key_duplicate`。**没有第四处。**

## 验收证据

反证 3/3 有效：

```
✅ D1 each key 改回 ts+action      → auditKey.test.js「key 用 e.id」FAILED
✅ D2 时长查表改回 ts+actor        → 同文件「两侧都不许拿 ts 当 key」FAILED
✅ D4 IPC 不再往外传 id            → audit_rows_in_the_same_millisecond_get_distinct_ids FAILED
```

新增测试：

- **Rust（真正的唯一性）**：`ipc_flow.rs::audit_rows_in_the_same_millisecond_get_distinct_ids`
  —— 塞 5 条 `ts` 完全相同的 `asset.removed_external`（就用用户那个
  `1787292449250`），`audit.list` 必须给出 5 个互不相同的 id。**顺带断言
  5 条的 ts 确实相同**，否则测试根本没在测撞键的前提
- **前端（防回改）**：`apps/desktop/src/auditKey.test.js` 源码级断言——
  遍历 `visibleAudit` 的 keyed each 必须用 `e.id`；`backupDuration` 的读写
  两侧都不许出现 `e.ts`

⚠️ **反证 D2 当场抓到我自己写窄的一条守卫**：第一版只断言了**读**侧
`backupDuration[e.ts`，而写侧是 `out[...]`——把写侧改回 `out[e.ts + ":" + who]`
测试照样绿。改成夹出 `backupDuration` 函数体、读写两侧一起断言。
**这是「函数级断言必须夹出函数体」这条教训的第三次复发**（前两次在
MOB-31 的 Kotlin 测试和 8/20 的 `sliceAfter`）。

`just ci` 全绿，Rust **314/314**，前端 vitest **18/18**（桌面端从 8 条涨到 18 条）。

## 真机确认（欠用户）

- 桌面端活动记录页：一次删 N 张照片后，N 条记录都在，控制台无 `each_key_duplicate`
