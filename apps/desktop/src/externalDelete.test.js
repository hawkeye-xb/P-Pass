// MOB-29: 桌面端「刚从库里删掉照片」警告的判据。
//
// 反证（判据不是恒真式）：把 `if (!e || e.action !== "asset.removed_external")`
// 那条过滤去掉，`add_and_move_never_warn` 立刻变红——它喂的全是
// `asset.relocated` / `ingest.*` 行。
import { describe, expect, it } from "vitest";
import {
  EXTERNAL_DELETE_WINDOW_MS,
  externalDeleteNotice,
} from "./lib/externalDelete.js";

const NOW = 1_787_300_000_000;
const del = (ts) => ({ action: "asset.removed_external", ts, detail: "originals missing: a.jpg" });

describe("externalDeleteNotice", () => {
  it("数出窗口内的外部删除条数 + 最近时刻", () => {
    const r = externalDeleteNotice([del(NOW - 1000), del(NOW - 2000)], NOW);
    expect(r).toEqual({ count: 2, latestAt: NOW - 1000 });
  });

  it("没有删除 = null（整块隐藏，不出空壳警告）", () => {
    expect(externalDeleteNotice([], NOW)).toBe(null);
    expect(externalDeleteNotice(null, NOW)).toBe(null);
    expect(externalDeleteNotice(undefined, NOW)).toBe(null);
  });

  it("add_and_move_never_warn：收录与挪位置不警告", () => {
    // WATCH-04「访达是布局的主人」——add/move 对我们影响为零，警告只
    // 出在唯一有代价的那个动作上。
    const events = [
      { action: "asset.relocated", ts: NOW - 500 },
      { action: "ingest.new", ts: NOW - 600 },
      { action: "ingest.duplicate", ts: NOW - 700 },
      { action: "backup.finished", ts: NOW - 800 },
    ];
    expect(externalDeleteNotice(events, NOW)).toBe(null);
  });

  it("陈年删除不再警告（超出时间窗）", () => {
    expect(externalDeleteNotice([del(NOW - EXTERNAL_DELETE_WINDOW_MS - 1)], NOW)).toBe(null);
    // 边界：正好在窗沿上算窗内。
    expect(externalDeleteNotice([del(NOW - EXTERNAL_DELETE_WINDOW_MS)], NOW)).toEqual({
      count: 1,
      latestAt: NOW - EXTERNAL_DELETE_WINDOW_MS,
    });
  });

  it("点过「知道了」之后不再警告，但新的删除会重新出现", () => {
    const events = [del(NOW - 5000)];
    expect(externalDeleteNotice(events, NOW, { dismissedAt: NOW - 5000 })).toBe(null);
    events.push(del(NOW - 100));
    expect(externalDeleteNotice(events, NOW, { dismissedAt: NOW - 5000 })).toEqual({
      count: 1,
      latestAt: NOW - 100,
    });
  });

  it("坏时间戳不算数，也不崩", () => {
    const events = [{ action: "asset.removed_external" }, { action: "asset.removed_external", ts: "x" }, null];
    expect(externalDeleteNotice(events, NOW)).toBe(null);
  });
});
