// 照片墙窗口对账的回归锁。
//
// 这个函数已经回归过两次：
//   DESK-06（8/13）修"墙压根不失效"→ 整墙清空重拉
//   8/17 去卡顿 → 换成增量合并，但只做了"插入新 hash"，于是
//        ①只看第一页 ②已有条目不更新 ③删除不消失 三个口子一起开
// 用户 2026-08-20 实测 186 张、拍摄时间跨 7 个月的库时全部撞上。
//
// 桌面端在此之前**零测试**，这是第一个。
import { describe, expect, it } from "vitest";
import { comparePhotoOrder, insertSorted, reconcilePhotoWall } from "./photoWall.js";

/** taken_at 是毫秒（真机实测：1787241443000）。 */
const p = (hash, takenAt, extra = {}) => ({
  hash,
  taken_at: takenAt,
  media_type: "photo",
  width: 100,
  height: 100,
  bytes: 1000,
  src_device: "dev",
  ...extra,
});

describe("排序键", () => {
  it("按拍摄时间降序，同时刻用 hash 兜底（与 daemon 的 ORDER BY 同源）", () => {
    expect(comparePhotoOrder(p("a", 200), p("b", 100))).toBeLessThan(0);
    expect(comparePhotoOrder(p("a", 100), p("b", 100))).toBeLessThan(0);
    expect(comparePhotoOrder(p("b", 100), p("a", 100))).toBeGreaterThan(0);
  });

  it("插入到正确位置——补录的老照片不许塞到最前面", () => {
    const arr = [p("n", 300), p("m", 200)];
    insertSorted(arr, p("old", 50));
    expect(arr.map((x) => x.hash)).toEqual(["n", "m", "old"]);
    insertSorted(arr, p("new", 999));
    expect(arr.map((x) => x.hash)).toEqual(["new", "n", "m", "old"]);
  });
});

describe("三向合并", () => {
  it("① 新到达的老照片必须出现（8/17 那版的第一个口子）", () => {
    // 墙上是 3 张较新的；同步中来了一张拍摄时间很老的。
    // 旧实现只拉第一页，一旦第一页被新照片占满，这张永远不出现。
    const held = [p("c", 300), p("b", 200), p("a", 100)];
    const fresh = [p("c", 300), p("b", 200), p("a", 100), p("ancient", 10)];
    const r = reconcilePhotoWall(held, fresh, true);
    expect(r.added).toBe(1);
    expect(r.items.map((x) => x.hash)).toEqual(["c", "b", "a", "ancient"]);
  });

  it("② 已有条目的元数据变化必须刷出来（第二个口子）", () => {
    // 缩略图/尺寸是异步补齐的——先以占位状态插进墙，之后到了要刷新。
    const held = [p("a", 100, { width: 0, height: 0 })];
    const fresh = [p("a", 100, { width: 4032, height: 3024 })];
    const r = reconcilePhotoWall(held, fresh, true);
    expect(r.updated).toBe(1);
    expect(r.items[0].width).toBe(4032);
  });

  it("③ 外部删除必须从墙上消失（第三个口子，DESK-06 修过又回来了）", () => {
    const held = [p("c", 300), p("gone", 200), p("a", 100)];
    const fresh = [p("c", 300), p("a", 100)];
    const r = reconcilePhotoWall(held, fresh, true);
    expect(r.removed).toBe(1);
    expect(r.items.map((x) => x.hash)).toEqual(["c", "a"]);
  });

  it("没变的条目保持同一个对象引用——否则缩略图会重新请求", () => {
    // Svelte 的 keyed each 按 hash 复用 DOM，但换了对象引用，子组件的
    // $derived/$effect 会重跑（缩略图重发请求）。逐字段比，没变就别动。
    const same = p("a", 100);
    const r = reconcilePhotoWall([same], [p("a", 100)], true);
    expect(r.updated).toBe(0);
    expect(r.items[0]).toBe(same);
  });
});

describe("移除的边界（最容易误删用户照片的地方）", () => {
  it("没走到库末尾时，区间之外缺席的一律保留", () => {
    // 墙上有深层分页的老照片；本次只重取了最新一段（没到末尾）。
    // 那些老照片不在 fresh 里**不等于被删了**——只是没拉到。
    const held = [p("c", 300), p("b", 200), p("deep", 10)];
    const fresh = [p("c", 300), p("b", 200)]; // 覆盖区间 [300, 200]
    const r = reconcilePhotoWall(held, fresh, /* reachedEnd */ false);
    expect(r.removed).toBe(0);
    expect(r.items.map((x) => x.hash)).toEqual(["c", "b", "deep"]);
  });

  it("没走到末尾，但缺席项落在覆盖区间内 = 真的没了", () => {
    const held = [p("c", 300), p("gone", 250), p("b", 200), p("deep", 10)];
    const fresh = [p("c", 300), p("b", 200)]; // 区间 [300,200] 内缺 gone
    const r = reconcilePhotoWall(held, fresh, false);
    expect(r.removed).toBe(1);
    expect(r.items.map((x) => x.hash)).toEqual(["c", "b", "deep"]);
  });

  it("重取为空且没到末尾 → 一个都不许删", () => {
    // 网络/IPC 抖动返回空页时，绝不能把墙清空。
    const held = [p("a", 100), p("b", 200)];
    const r = reconcilePhotoWall(held, [], false);
    expect(r.removed).toBe(0);
    expect(r.items).toHaveLength(2);
  });

  it("库真的空了（走到末尾且为空）→ 墙清空", () => {
    const r = reconcilePhotoWall([p("a", 100)], [], true);
    expect(r.removed).toBe(1);
    expect(r.items).toHaveLength(0);
  });
});

describe("批量同步（用户 2026-08-20 撞到的真实场景）", () => {
  it("186 张跨 7 个月、到达顺序与拍摄时间无关 —— 全部都要上墙", () => {
    // 手机按 MediaStore 修改代号升序扫，与拍摄时间无关。模拟：墙上先有
    // 60 张（第一页），随后到达的 126 张拍摄时间散布在整个区间。
    const all = Array.from({ length: 186 }, (_, i) =>
      p(`h${String(i).padStart(3, "0")}`, 1_700_000_000_000 + i * 86_400_000)
    );
    const sorted = [...all].sort(comparePhotoOrder);
    const held = sorted.slice(0, 60); // 墙上是最新 60 张
    // 重取覆盖整个窗口 + 到达末尾
    const r = reconcilePhotoWall(held, sorted, true);
    expect(r.added).toBe(126);
    expect(r.items).toHaveLength(186);
    // 顺序必须与 daemon 的排序完全一致
    expect(r.items.map((x) => x.hash)).toEqual(sorted.map((x) => x.hash));
  });
});

// ── 接线（源码级）──
//
// 纯函数有测试、**调用点没有**：反证实测撞到——把 App.svelte 里的重取上限
// 改回"只拉第一页"（回归 2026-08-17 那版的第一个口子），11 个测试全绿。
// 所以判据里"重取覆盖整个已加载窗口"这件事必须单独锁住。
import { readFileSync } from "node:fs";

/** 剥掉注释再断言——否则解释性文字会被当成代码（Android 侧同一教训）。 */
function codeOf(path) {
  return readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("//"))
    .join("\n");
}

describe("App.svelte 的接线", () => {
  const src = codeOf(new URL("./App.svelte", import.meta.url).pathname);
  const body = (() => {
    const i = src.indexOf("async function syncPhotosWallIncremental()");
    expect(i).toBeGreaterThan(-1);
    const tail = src.slice(i);
    const j = tail.indexOf("\n  }");
    expect(j).toBeGreaterThan(-1);
    return tail.slice(0, j);
  })();

  it("重取必须覆盖整个已加载窗口，不是只拉第一页", () => {
    // 墙按拍摄时间排、页大小 60；只拉第一页的话，第一页被较新的占满之后，
    // 后到的老照片永远不出现（用户 2026-08-20 实测 186 张跨 7 个月的库）。
    expect(body).toContain("const cap = held + PHOTOS_PAGE_SIZE");
    expect(body).toMatch(/while \(fresh\.length < cap\)/);
    // 必须真的翻页——只调一次 timeline.page 等于只拉第一页。
    expect(body).toContain("cursor = r.next ?? null");
  });

  it("必须走共用的三向合并，不许在这里另写一份判据", () => {
    expect(body).toContain("reconcilePhotoWall(photos, fresh, reachedEnd)");
    // 旧实现的标志物：只 filter 新增。留着就说明判据又分叉了。
    expect(body).not.toContain("!known.has(it.hash)");
  });

  it("必须防重入——批量同步时事件密集，重叠重取会互相打乱", () => {
    // ⚠️ 断言要盯**那道闸本身**：只判 `toContain("photosSyncing")` 拦不住
    // 把它从 guard 里删掉——赋值语句里还有这个词，测试照样绿（反证实测）。
    expect(body).toContain("if (!photosLoaded || photosSyncing) return");
    expect(body).toMatch(/photosSyncing = true/);
    expect(body).toMatch(/photosSyncing = false/);
  });

  it("活动记录右侧只有一行时间，精确时刻进 tooltip", () => {
    // 用户 2026-08-20 反馈：右侧堆两行（相对+精确）指同一个瞬间，是重复
    // 表达；而左侧 items-baseline 对齐第一行，第二行往下撑就在左边留出空白。
    const li = src.slice(src.indexOf("{#each visibleAudit as e"));
    const row = li.slice(0, li.indexOf("{/each}"));
    expect(row).toContain('title={exact ?? ""}');
    // 不许再出现"把 exact 单独渲染成一行"的形状。
    expect(row).not.toMatch(/<span[^>]*>\{exact\}<\/span>/);
  });
});
