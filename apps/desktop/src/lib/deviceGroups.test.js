// #1699：removal 值未知的设备不能整行消失（fail-open）。
// 反证：把 deviceGroupKey 改回精确匹配（只认 "none"/"disconnected"，
// 其余返回 null 并被丢弃），下面三条未知值用例全变红。
import { test, expect } from "vitest";
import { deviceGroupKey, deviceGroups } from "./deviceGroups.js";

const byActivity = (a, b) => (b.last_activity_at ?? 0) - (a.last_activity_at ?? 0);

test("已知值各归各组，业主已移除的不渲染", () => {
  expect(deviceGroupKey({ removal: "none" })).toBe("paired");
  expect(deviceGroupKey({ removal: "disconnected" })).toBe("disconnected");
  expect(deviceGroupKey({ removal: "removed" })).toBe("removed");

  const groups = deviceGroups(
    [
      { node_id: "a", removal: "none", last_activity_at: 1 },
      { node_id: "b", removal: "removed", last_activity_at: 2 },
    ],
    byActivity
  );
  expect(groups.map((g) => g.key)).toEqual(["paired"]);
  expect(groups[0].items.map((d) => d.node_id)).toEqual(["a"]);
});

test("未知字符串、空串、缺字段都留在列表里（归到第二组）", () => {
  for (const removal of ["unknown", "", undefined]) {
    expect(deviceGroupKey({ removal })).toBe("disconnected");
  }

  const devices = [
    { node_id: "known", removal: "none", last_activity_at: 3 },
    { node_id: "unknown-str", removal: "unknown", last_activity_at: 2 },
    { node_id: "empty", removal: "", last_activity_at: 1 },
    { node_id: "missing", last_activity_at: 0 },
  ];
  const groups = deviceGroups(devices, byActivity);
  expect(groups.map((g) => g.key)).toEqual(["paired", "disconnected"]);
  expect(groups[0].items.map((d) => d.node_id)).toEqual(["known"]);
  expect(groups[1].items.map((d) => d.node_id)).toEqual(["unknown-str", "empty", "missing"]);
  // 一台都不能丢
  const rendered = groups.flatMap((g) => g.items);
  expect(rendered).toHaveLength(devices.length);
});

test("组内按最近活跃倒序，空组不返回", () => {
  const groups = deviceGroups(
    [
      { node_id: "old", removal: "none", last_activity_at: 1 },
      { node_id: "new", removal: "none", last_activity_at: 9 },
    ],
    byActivity
  );
  expect(groups).toHaveLength(1);
  expect(groups[0].items.map((d) => d.node_id)).toEqual(["new", "old"]);
  expect(deviceGroups([], byActivity)).toEqual([]);
});
