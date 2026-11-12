// #1699 / #1577：设备页主列表分组。
//
// #253 定下的口径是「展示层不过滤」：只有确定是业主主动移除的行才收起，
// 拿不准的行一律留在列表里。这里按这个口径分组：
//   - removal === "none"      → 「已配对」
//   - removal === "removed"   → 业主已移除，不渲染（#1577）
//   - 其余一切值（"disconnected"、未知字符串、空串、字段缺失）
//                             → 「已断开」组（非在用、非业主移除的那一组）
//
// 最后一条是有意的 fail-open：daemon 少给字段、给空值或以后新增状态时，
// 这台设备仍然看得见、点得到「移除」，不会因为一个对不上的字符串整行消失。
// 新增「不该出现在主列表」的 removal 值时要同步改这里。

export const DEVICE_GROUPS = [
  { key: "paired", title: "ui.devices_group_paired" },
  { key: "disconnected", title: "ui.disconnected" },
];

/** 一行该进哪一组；"removed" 表示不渲染。 */
export function deviceGroupKey(d) {
  if (d?.removal === "none") return "paired";
  if (d?.removal === "removed") return "removed";
  return "disconnected";
}

/** 按 deviceGroupKey 分组，组内按 byActivity 倒序，空组不返回。 */
export function deviceGroups(devices, byActivity) {
  const groups = DEVICE_GROUPS.map((g) => ({ ...g, items: [] }));
  for (const d of devices ?? []) {
    const key = deviceGroupKey(d);
    if (key === "removed") continue;
    groups.find((g) => g.key === key).items.push(d);
  }
  for (const g of groups) g.items.sort(byActivity);
  return groups.filter((g) => g.items.length > 0);
}
