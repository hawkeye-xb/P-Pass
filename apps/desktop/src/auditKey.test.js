// DESK-08 回归锁：活动流的 #each key 必须是审计主键，不是时间戳拼串。
//
// 现场（2026-08-21 用户真机）：WATCH-02 一次删 5 张照片 → 5 条
// `asset.removed_external` **全落在同一毫秒**（ts=1787292449250）。App.svelte
// 的 `#each visibleAudit as e (e.ts + ":" + e.action)` 立刻撞键：
//
//   Svelte error: each_key_duplicate
//   Keyed each block has duplicate key `1787292449250:asset.removed_external`
//
// 整个活动流挂掉。**时间戳不是身份，主键才是。**
//
// 这是源码级断言：真正的唯一性由 Rust 侧
// `audit_rows_in_the_same_millisecond_get_distinct_ids` 钉死（那条测的是
// audit.list 真的给出互不相同的 id）。这里只防"有人把 key 改回去"。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const src = readFileSync(
  join(dirname(fileURLToPath(import.meta.url)), "App.svelte"),
  "utf8",
);

/** 夹出所有 keyed `#each` 的 key 表达式。 */
function eachKeys(s) {
  return [...s.matchAll(/\{#each\s+([^}]*?)\s+as\s+([^(}]*?)\(([^)]*)\)\}/g)].map(
    (m) => ({ list: m[1].trim(), key: m[3].trim() }),
  );
}

/** 带右边界的切片。锚点消失时**必须失败**，不能静默返回空串
 *  —— 空串上的 `not.toMatch` 恒真，那种"绿"是假的。 */
function sliceBetween(s, from, to) {
  const i = s.indexOf(from);
  expect(i, `源码锚点已消失，断言失效：${from}`).toBeGreaterThanOrEqual(0);
  const tail = s.slice(i + from.length);
  const j = tail.indexOf(to);
  expect(j, `源码结束锚点已消失，断言失效：${to}`).toBeGreaterThanOrEqual(0);
  return tail.slice(0, j);
}

describe("活动流的 each key", () => {
  it("锚点还在——App.svelte 里确实有遍历 visibleAudit 的 keyed each", () => {
    const audit = eachKeys(src).filter((e) => e.list.includes("visibleAudit"));
    // ⚠️ 没有这条断言，下面那个 every() 在零元素上恒真（正则一改就静默失效）。
    expect(audit.length).toBeGreaterThanOrEqual(2);
  });

  it("key 用 e.id，不许拿 ts 拼", () => {
    for (const { list, key } of eachKeys(src).filter((e) =>
      e.list.includes("visibleAudit"),
    )) {
      expect(key, `each ${list} 的 key`).toBe("e.id");
      expect(key).not.toMatch(/\bts\b/);
    }
  });

  it("时长查表两侧都不许拿 ts 当 key（同形的撞键风险）", () => {
    // ⚠️ 第一版只断言了**读**侧 `backupDuration[e.ts` ——而写侧是
    // `out[...]`，把写侧改回 `out[e.ts + ":" + who]` 测试照样绿（反证
    // D2 当场抓到）。**夹出函数体，两侧一起管。**
    const body = sliceBetween(src, "const backupDuration = $derived.by(", "});");
    expect(body).toContain("out[e.id]");
    expect(body).not.toMatch(/out\[\s*e\.ts/);
    // 读侧
    expect(src).toContain("backupDuration[e.id]");
    expect(src).not.toMatch(/backupDuration\[\s*e\.ts/);
  });
});
