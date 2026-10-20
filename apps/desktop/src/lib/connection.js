// devices.list[].connection / presence → 设备行 sub 文案 + 状态点色。
// 纯函数，无 DOM/Tauri 依赖。I18N-03 (#492) 起文案经 ./i18n.js 取自
// assets/i18n（JSON import 要 Vite/vitest 解析），裸 node 不能直跑。
//
// 契约（crates/daemon/src/ipc.rs devices.list）：connection 是四态字符串
// "direct" | "relay" | "offline" | "unknown"——只报活连接事实，
// "unknown" = 没有活的连接信息（daemon 绝不从 last_seen 推导）。

import { t } from "./i18n.js";

/**
 * NET-05: only an active Flow fetch supplies this nullable field. The wording
 * names a transfer rather than claiming a device is generally direct/relay.
 * null means fall back to the established presence projection.
 */
export function flowConnectionText(flowConnection) {
  switch (flowConnection) {
    case "direct":
      return { sub: t("ui.flow_direct"), dot: "safe" };
    case "relay":
      return { sub: t("ui.flow_relay"), dot: "wait" };
    case "unknown":
      return { sub: t("ui.flow_unknown"), dot: "wait" };
    default:
      return null;
  }
}

/**
 * PRES-01: presence 三档 → 设备行 sub 文案 + 点色。
 * 契约（crates/daemon/src/presence.rs）：presence = "online" | "recent" |
 * "offline"。online 优先展示连接路径事实（已直连/经中继）；心跳新鲜但
 * 无活连接 → 泛化「在线」。recent → 「x 分钟前在线」（relativeText 是
 * relativeTime 输出）；offline → 保留旧话术「离线，最后在线 <日历时间>」，
 * 无 last_seen → 「等待下次备份上报」（中性，不捏造）。哨兵红由调用方
 * （deviceRow）在 presence 之前裁决，优先级最高。
 * @param {string} presence
 * @param {string} connection devices.list[].connection 四态
 * @param {string|null} relativeText relativeTime 输出（recent 用）
 * @param {string|null} humanText humanTime 输出（offline 用）
 */
export function presenceText(presence, connection, relativeText = null, humanText = null) {
  switch (presence) {
    case "online":
      if (connection === "direct") return { sub: t("ui.conn_direct"), dot: "safe" };
      if (connection === "relay") return { sub: t("ui.conn_relay"), dot: "wait" };
      return { sub: t("ui.presence_online"), dot: "safe" }; // 心跳新鲜，无活连接
    case "recent":
      return { sub: relativeText ? t("ui.presence_recent", { time: relativeText }) : t("ui.presence_just_now"), dot: "idle" };
    case "offline":
    default:
      return {
        sub: humanText ? t("ui.conn_offline_since", { time: humanText }) : t("ui.presence_waiting"),
        dot: "idle",
      };
  }
}
