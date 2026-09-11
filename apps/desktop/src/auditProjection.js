// AUDIT-02: canonical audit operations → user-facing activity text.
// This module deliberately receives only daemon-provided evidenceSummary:
// phone final_counts are advisory and must never determine displayed counts.

const HIDDEN_KINDS = new Set([
  "device.connected",
  "flow.round.controlled",
  "flow.scope.changed",
  "flow.epoch.invalidated",
]);

function count(summary, key) {
  const value = summary?.[key];
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function shortName(path) {
  const text = String(path ?? "");
  const index = Math.max(text.lastIndexOf("/"), text.lastIndexOf("\\"));
  return index >= 0 ? text.slice(index + 1) : text;
}

function backupResult(summary) {
  const confirmed = count(summary, "confirmed");
  const needsAttention = count(summary, "failed") + count(summary, "remote_missing");
  const skipped = count(summary, "source_missing");
  const parts = [];

  if (confirmed) parts.push(`已备份 ${confirmed} 张照片`);
  if (needsAttention) parts.push(`${needsAttention} 张需处理`);
  if (skipped) parts.push(`${skipped} 张已跳过`);
  return parts.length ? parts.join("；") : "备份完成";
}

export function isVisibleAudit(event) {
  const kind = event?.kind;
  return Boolean(kind) && !kind.startsWith("ingest.") && !kind.startsWith("flow.item.") && !HIDDEN_KINDS.has(kind);
}

export function auditWho(event, devices) {
  const payload = event?.payload ?? {};
  const actor = event?.actor;
  const device = devices.find((item) => item.node_id === actor);
  if (device) return `${device.name} · #${actor.slice(0, 8)}`;
  if (event?.kind?.startsWith("pair.") && payload.deviceName) return payload.deviceName;
  if (actor) return `未知设备 · #${actor.slice(0, 8)}`;
  return "【本地】";
}

export function auditText(event) {
  const payload = event?.payload ?? {};
  switch (event?.kind) {
    case "pair.requested":
      return "请求加入";
    case "pair.accepted":
      return "已加入";
    case "pair.denied":
      return "加入被拒绝";
    case "asset.removed_external":
      return `外部删除（${shortName(payload.relPath)}）`;
    case "device.renamed":
      return payload.oldName && payload.newName ? `改名：${payload.oldName} → ${payload.newName}` : "已改名";
    case "device.revoked":
      return "已移除设备";
    case "device.unpaired":
      return "主动断开连接";
    case "device.merged":
      return "合并旧设备（重装恢复）";
    case "flow.round.finished":
      return backupResult(event.evidenceSummary);
    case "flow.reconciliation.resolved":
      return "对账裁决完成";
    default:
      return "发生了一条未分类的活动";
  }
}
