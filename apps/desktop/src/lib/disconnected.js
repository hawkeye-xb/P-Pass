// DEV-03（2026-09-20 验收人定调）：设备离开「家人与设备」有两种方式，
// 必须分开——此前两条路都只是 `revoked = 1`，于是列表一刀切按
// `WHERE revoked = 0` 过滤，手机一断开设备就从列表里凭空消失。
//
// 验收人原话：
//
// > 主动断开，desktop 可以标记断开，但是不能删数据啊。
// > 又不是我主动移除的。
// > 不要主动让它在设备表里消失，因为它可能改过名称。
// > 我得知道，回头审计时要明确到底是哪个设备。
//
// 纯函数，无 DOM/Tauri 依赖，node 可直跑（同 connection.js 的惯例）。
//
// 契约（crates/daemon/src/ipc.rs devices.list）：
//   revoked     bool
//   revoked_by  "device" | "owner" | null
//   revoked_at  unix ms | null
//
// `null` = DEV-03 这两列加上之前留下的历史行，来源不可考。**按「业主移除」
// 处理**——保守方向：宁可让一台老设备不出现在主列表，也不要凭空冒出一台
// 业主早就移除掉的。

/** 这台是「自己断开的」吗——该留在主列表里标「已断开」。 */
export function isSelfDisconnected(device) {
  return Boolean(device?.revoked) && device?.revoked_by === "device";
}

/** 这台是「业主移除的」吗——该收进折叠区。 */
export function isOwnerRemoved(device) {
  return Boolean(device?.revoked) && device?.revoked_by !== "device";
}

/**
 * 已断开设备的行文案。
 *
 * 刻意**不**复用 `presenceText`：那一套讲的是「连接活没活」，而断开是
 * **授权**上的终止。一台刚断开、连接还没散干净的设备如果显示「离线，
 * 最后在线 3 分钟前」，读起来像「它还在备份，只是暂时不在线」——正好相反。
 *
 * @param {object} device devices.list 的一行
 * @param {string|null} disconnectedAtText 已人性化的断开时刻（humanTime 输出）
 */
export function disconnectedRow(device, disconnectedAtText = null) {
  if (!isSelfDisconnected(device)) return null;
  return {
    alert: false,
    dot: "idle",
    // 「已断开 · <时刻>」就够了。后半句「在这台手机上断开了连接」是把
    // 「已断开」又说了一遍，占着一整列却不带新信息（2026-09-20 验收人
    // 本地验收后拍掉）。
    sub: disconnectedAtText ? `已断开 · ${disconnectedAtText}` : "已断开",
    right: "重新扫码即可恢复",
  };
}
