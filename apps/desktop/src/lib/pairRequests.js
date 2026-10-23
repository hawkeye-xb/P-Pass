// 「有设备请求加入」弹窗的视图模型：一块 = 一次申请，不是一台设备。
//
// 申请 id = node_id + requested_at：同一台手机重新扫码是一次新申请，从干净状态开始，
// 不会继承上一次的错误或输入（真机实测：错误按 node_id 存，重扫后新申请还挂着旧错误、
// 按钮被藏起来）。
//
// 每块有自己的阶段：
//   input  —— 等主人输验证码；daemon 队列里没了（撤回/过期/别处处理了）就随之消失。
//   busy   —— pairing.confirm 正在等手机回执；队列先没了也留着，等结果。
//   failed —— 码错，这次申请已作废（daemon 已撤）；留在弹窗里，直到主人点「知道了」。
// 弹窗开不开看这里还有没有块，不看 daemon 队列是否为空——队列在 confirm 返回前就会
// 变空（daemon 先撤行、推 pending_changed，再回复），按队列关弹窗会把错误一起关掉。

/** 一次申请的 id。 */
export function requestId(item) {
  return `${item?.node_id ?? item?.name ?? ""}:${item?.requested_at ?? ""}`;
}

/**
 * 用 daemon 的最新队列对齐弹窗里的块。
 * @returns {{ rows: Array<{id: string, item: object, phase: string}>, added: string[] }}
 */
export function syncRequests(rows, pendingList) {
  const pending = Array.isArray(pendingList) ? pendingList : [];
  const byId = new Map(rows.map((r) => [r.id, r]));
  const live = new Set();
  const added = [];
  const next = [];
  for (const item of pending) {
    const id = requestId(item);
    live.add(id);
    const old = byId.get(id);
    if (old) next.push({ ...old, item });
    else {
      next.push({ id, item, phase: "input" });
      added.push(id);
    }
  }
  // 队列里没了的：等结果的、已作废待确认的留下，其余随之消失。
  for (const r of rows) {
    if (!live.has(r.id) && (r.phase === "busy" || r.phase === "failed")) next.push(r);
  }
  return { rows: next, added };
}

export function setPhase(rows, id, phase) {
  return rows.map((r) => (r.id === id ? { ...r, phase } : r));
}

export function removeRequest(rows, id) {
  return rows.filter((r) => r.id !== id);
}
