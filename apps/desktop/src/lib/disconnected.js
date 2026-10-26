// DEV-03（2026-09-20 验收人定调）：设备离开「家人与设备」有不同方式，
// 必须分开——手机自己断开不是业主的意图，它要留在主列表里标「已断开」。
//
// 验收人原话：
//
// > 主动断开，desktop 可以标记断开，但是不能删数据啊。
// > 又不是我主动移除的。
// > 不要主动让它在设备表里消失，因为它可能改过名称。
// > 我得知道，回头审计时要明确到底是哪个设备。
//
// #1117 口径：**设备档案与审计永不删除，配对记录可以物理删除。**「不能删
// 数据」指的是档案（它是谁、叫什么、什么时候离开的）与审计；断开、撤销、
// 电脑换身份删的是配对记录（它凭什么能连），这台设备的档案照样留在列表里。
//
// 纯函数，无 DOM/Tauri 依赖，node 可直跑（同 connection.js 的惯例）。
//
// 契约（crates/daemon/src/ipc.rs devices.list）：
//   paired        bool                                    有没有配对记录
//   departed_by   "device" | "owner" | "identity" | null  配对记录为什么被删
//   departed_at   unix ms | null
//
// 哪一行进主列表、哪一行是「已断开」由 daemon 判定（`removal` / `row_state`），
// 这里只出文案。

import { t } from "./i18n.js";

/**
 * 已断开设备的行文案。
 *
 * 刻意**不**复用 `presenceText`：那一套讲的是「连接活没活」，而断开是
 * **授权**上的终止。一台刚断开、连接还没散干净的设备如果显示「离线，
 * 最后在线 3 分钟前」，读起来像「它还在备份，只是暂时不在线」——正好相反。
 *
 * 哪一行是「已断开」由 daemon 判定（devices.list 的 `row_state`，#1044），
 * 这里只出文案。
 *
 * @param {string|null} disconnectedAtText 已人性化的断开时刻（humanTime 输出）
 * @param {string|null} departedBy devices.list 的 `departed_by`；`"identity"` =
 *   这台电脑换了身份（#1109），提示语说明要重新扫码的原因。
 */
export function disconnectedRow(disconnectedAtText = null, departedBy = null) {
  return {
    alert: false,
    dot: "idle",
    // 「已断开 · <时刻>」就够了。后半句「在这台手机上断开了连接」是把
    // 「已断开」又说了一遍，占着一整列却不带新信息（2026-09-20 验收人
    // 本地验收后拍掉）。
    sub: disconnectedAtText ? t("ui.disconnected_at", { time: disconnectedAtText }) : t("ui.disconnected"),
    right: departedBy === "identity" ? t("ui.disconnected_identity_hint") : t("ui.disconnected_hint"),
  };
}
