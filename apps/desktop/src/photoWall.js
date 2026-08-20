// 照片墙的窗口对账 —— 纯函数，零 Svelte / 零 IPC 依赖，可单测。
//
// ## 墙持有的是什么
//
// 墙是一个**前缀窗口**：按 `taken_at` 降序（daemon
// `asset_repo.rs::timeline_page` 的 `ORDER BY COALESCE(taken_at,0) DESC,
// hash ASC`）的前 K 条。用户往下滚就把 K 变大。
//
// ## 为什么需要这个函数（两次回归的教训）
//
// - **DESK-06（2026-08-13）**：墙压根不失效——Finder 删照片手机端立刻消失、
//   桌面端纹丝不动。修法是收到 `timeline.invalidated` 就整墙清空重拉。
// - **2026-08-17（去卡顿）**：整墙清空重拉会销毁所有已渲染的缩略图 DOM，
//   来一次事件卡一下。于是改成"增量合并"——但那版只做了两件事里的一件：
//
//   ```js
//   const r = await call("timeline.page", { cursor: null, limit: 60 });  // 只拉第一页
//   const arrivals = fresh.filter(it => !known.has(it.hash));            // 只插新 hash
//   ```
//
//   于是开了三个口子，全都在批量同步时暴露（用户 2026-08-20 实测 186 张
//   跨 7 个月拍摄时间的库）：
//   1. **只看第一页**：墙按拍摄时间排，页大小 60。到达顺序与拍摄时间无关
//      （手机按 MediaStore 的修改代号升序扫），第一页被 60 张较新的占满之后，
//      后到的老照片**永远不出现**。
//   2. **已有条目永不更新**：缩略图是按需生成的，先以占位状态插进墙，之后
//      缩略图到了也不会刷新那一格。
//   3. **删除永不消失**：只 filter 新增、从不移除——DESK-06 修的那个问题
//      悄悄回来了。
//
// ## 正确的口径
//
// 对账 = **重取同一个窗口**，按 hash 三向合并：新增插入、已有原地更新、
// 窗口内消失的移除。三个用例一次盖住。
//
// 不卡的关键不是"少拉数据"，是**原地打补丁而不是清空重建**——卡顿来自
// `photos = []` 销毁 DOM，不来自重取几十条元数据（缩略图是按 hash 独立
// 请求 + 缓存的，元数据刷新不会让它重新下载）。

/** 墙的排序键比较（与 daemon 的 ORDER BY 同源，否则插入位置会错）。 */
export function comparePhotoOrder(a, b) {
  const ta = a.taken_at ?? 0;
  const tb = b.taken_at ?? 0;
  if (ta !== tb) return tb - ta;
  return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0;
}

/**
 * 三向合并。
 *
 * @param held      墙上现有条目（按排序键降序）
 * @param fresh     本次重取到的条目（同序，覆盖 held 的前缀窗口）
 * @param reachedEnd 本次重取是否走到了库的末尾
 * @returns {{items: Array, added: number, updated: number, removed: number}}
 *
 * ## 移除的边界（这里最容易出错）
 *
 * 一个持有项不在 `fresh` 里，**不等于它被删了**——也可能只是被新到达的更新
 * 照片挤出了本次重取的范围。所以只有两种情况才敢移除：
 *
 * - 重取走到了库末尾（`reachedEnd`）→ `fresh` 就是全部真相，缺的就是没了
 * - 该项的排序键落在 `fresh` 覆盖的**闭区间内**→ 区间内缺席 = 真的没了
 *
 * 区间之外一律保留。宁可多留一格（下次滚动/刷新会纠正），不可凭空删掉
 * 用户的照片格子。
 *
 * ## 原地更新的口径
 *
 * 已有 hash 的条目**只有字段真的变了才替换对象**。Svelte 的 keyed each 按
 * hash 复用 DOM，但如果每次都换一个新对象引用，子组件的 `$derived`/`$effect`
 * 会重新跑（缩略图请求重发）。所以要逐字段比，没变就原样留着。
 */
export function reconcilePhotoWall(held, fresh, reachedEnd) {
  const freshByHash = new Map(fresh.map((it) => [it.hash, it]));
  const covered = coveredRange(fresh);

  const items = [];
  let updated = 0;
  let removed = 0;

  for (const cur of held) {
    const next = freshByHash.get(cur.hash);
    if (next) {
      if (samePhoto(cur, next)) {
        items.push(cur); // 一模一样——保持同一个对象引用，DOM 与缩略图都不动
      } else {
        items.push(next);
        updated += 1;
      }
      continue;
    }
    // 不在本次重取里。只有能证明"确实没了"才移除。
    if (reachedEnd || inRange(cur, covered)) {
      removed += 1;
      continue;
    }
    items.push(cur); // 证明不了 → 保留
  }

  // 新到达的插到正确位置（按排序键，不是无脑塞最前面——补录的老照片
  // taken_at 可能很老）。
  const heldHashes = new Set(held.map((p) => p.hash));
  let added = 0;
  for (const it of fresh) {
    if (heldHashes.has(it.hash)) continue;
    insertSorted(items, it);
    added += 1;
  }

  return { items, added, updated, removed };
}

/** 本次重取覆盖的排序键闭区间（空则为 null）。 */
function coveredRange(fresh) {
  if (fresh.length === 0) return null;
  return { first: fresh[0], last: fresh[fresh.length - 1] };
}

function inRange(item, range) {
  if (!range) return false;
  return (
    comparePhotoOrder(range.first, item) <= 0 && comparePhotoOrder(item, range.last) <= 0
  );
}

/** 展示相关的字段全比一遍。漏一个字段 = 那个字段的变化永远刷不出来。 */
function samePhoto(a, b) {
  return (
    a.taken_at === b.taken_at &&
    a.media_type === b.media_type &&
    a.width === b.width &&
    a.height === b.height &&
    a.bytes === b.bytes &&
    a.src_device === b.src_device
  );
}

export function insertSorted(arr, item) {
  let lo = 0;
  let hi = arr.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (comparePhotoOrder(arr[mid], item) <= 0) lo = mid + 1;
    else hi = mid;
  }
  arr.splice(lo, 0, item);
  return arr;
}
