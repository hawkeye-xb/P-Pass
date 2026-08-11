// T-092: devices.list[].connection → 设备行 sub 文案 + 状态点色。
// 纯函数，无 DOM/Tauri 依赖，node 可直跑
// （apps/desktop/scripts/check-wire-fns.mjs 是对应断言脚本）。
//
// 契约（crates/daemon/src/ipc.rs devices.list）：connection 是四态字符串
// "direct" | "relay" | "offline" | "unknown"——只报活连接事实，
// "unknown" = 没有活的连接信息（daemon 绝不从 last_seen 推导）。
// 话术为设计稿/T-092 卡原文；unknown 返回 null，调用方保持 T-082
// 中性占位（不捏造「已直连」）。

/**
 * connection → 设备行次行文案。
 * direct  → 「已直连」
 * relay   → 「经中继连接——内容加密，中继无法读取」
 * offline → 「离线，最后在线 <人性化时间>」；没有可用的最后在线时间时只说「离线」
 * unknown/其它 → null（调用方用 T-082 中性占位）
 * @param {string} connection
 * @param {string|null} lastSeenText 已人性化的最后在线时间（humanTime 输出，可能 null）
 */
export function connectionText(connection, lastSeenText = null) {
  switch (connection) {
    case "direct":
      return "已直连";
    case "relay":
      return "经中继连接——内容加密，中继无法读取";
    case "offline":
      return lastSeenText ? `离线，最后在线 ${lastSeenText}` : "离线";
    default:
      return null;
  }
}

/**
 * connection → 状态点色 token 名（tokens.css 语义色：绿=safe 琥珀=wait 灰=idle）。
 * direct→"safe"，relay→"wait"，offline/unknown/其它→"idle"。
 * 哨兵红（act）优先级更高，由调用方（deviceRow）裁决，不在本映射里。
 */
export function connectionDot(connection) {
  switch (connection) {
    case "direct":
      return "safe";
    case "relay":
      return "wait";
    default:
      return "idle";
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
      if (connection === "direct") return { sub: "已直连", dot: "safe" };
      if (connection === "relay") return { sub: "经中继连接——内容加密，中继无法读取", dot: "wait" };
      return { sub: "在线", dot: "safe" }; // 心跳新鲜，无活连接
    case "recent":
      return { sub: relativeText ? `${relativeText}在线` : "刚刚在线", dot: "idle" };
    case "offline":
    default:
      return {
        sub: humanText ? `离线，最后在线 ${humanText}` : "等待下次备份上报",
        dot: "idle",
      };
  }
}
