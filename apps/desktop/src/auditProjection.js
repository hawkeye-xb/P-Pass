// AUDIT-02: canonical audit operations → user-facing activity text.
// #1044 B1：哪些事件给用户看、每轮计数怎么分类，都由 daemon 决定
// （crates/daemon/src/audit_projection.rs；`audit.list(visibility:"user")`
// 已在截断前过滤，`flow.round.finished` 带分好类的 `counts`）。本模块只按
// kind 取文案。

import { t } from "./lib/i18n.js";

function count(counts, key) {
  const value = counts?.[key];
  return Number.isSafeInteger(value) && value > 0 ? value : 0;
}

function shortName(path) {
  const text = String(path ?? "");
  const index = Math.max(text.lastIndexOf("/"), text.lastIndexOf("\\"));
  return index >= 0 ? text.slice(index + 1) : text;
}

function backupResult(counts) {
  const confirmed = count(counts, "backedUp");
  const needsAttention = count(counts, "needsAttention");
  const skipped = count(counts, "skipped");
  const parts = [];

  if (confirmed) parts.push(t("ui.audit_backed_up", { n: confirmed }));
  if (needsAttention) parts.push(t("ui.audit_needs_attention", { n: needsAttention }));
  if (skipped) parts.push(t("ui.audit_skipped", { n: skipped }));
  return parts.length ? parts.join(t("ui.audit_part_sep")) : t("ui.audit_backup_done");
}

export function auditWho(event, devices) {
  const payload = event?.payload ?? {};
  const actor = event?.actor;
  const device = devices.find((item) => item.node_id === actor);
  if (device) return `${device.name} · #${actor.slice(0, 8)}`;
  if (event?.kind?.startsWith("pair.") && payload.deviceName) return payload.deviceName;
  if (actor) return t("ui.audit_unknown_device", { id: actor.slice(0, 8) });
  return t("ui.audit_local");
}

export function auditText(event) {
  const payload = event?.payload ?? {};
  switch (event?.kind) {
    case "pair.requested":
      return t("ui.audit_pair_requested");
    case "pair.accepted":
      return t("ui.audit_pair_accepted");
    case "pair.denied":
      return t("ui.audit_pair_denied");
    case "pair.cancelled":
      return t("ui.audit_pair_cancelled");
    case "pair.expired":
      return t("ui.audit_pair_expired");
    case "asset.removed_external":
      return t("ui.audit_removed_external", { name: shortName(payload.relPath) });
    case "device.renamed":
      return payload.oldName && payload.newName
        ? t("ui.audit_renamed_from_to", { old: payload.oldName, new: payload.newName })
        : t("ui.audit_renamed");
    case "device.revoked":
      return t("ui.audit_revoked");
    case "device.unpaired":
      return t("ui.audit_unpaired");
    case "device.merged":
      return t("ui.audit_merged");
    case "flow.round.finished":
      return backupResult(event.counts);
    case "flow.reconciliation.resolved":
      return t("ui.audit_reconciled");
    default:
      return t("ui.audit_unknown");
  }
}
