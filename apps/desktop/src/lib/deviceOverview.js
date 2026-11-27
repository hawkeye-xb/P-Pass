import { flowConnectionText, presenceText } from "./connection.js";
import { disconnectedRow } from "./disconnected.js";
import { daysSince, humanTime, relativeTime } from "./humanTime.js";
import { t } from "./i18n.js";
import { staleHint } from "./staleHint.js";

const OVERVIEW_ROWS = 3;

export const byActivity = (a, b) => (b.last_activity_at ?? 0) - (a.last_activity_at ?? 0);

export function deviceRow(d, wm, now) {
  const lastBackupAt = wm?.last_backup_at ?? null;
  const backupTime = humanTime(lastBackupAt, now);
  const backupRight = backupTime ? t("ui.device_last_backup", { time: backupTime }) : t("ui.device_never_backed_up");
  switch (d.row_state) {
    case "disconnected":
      return disconnectedRow(humanTime(d.departed_at, now), d.departed_by);
    case "needs_attention":
      return {
        alert: true,
        dot: "act",
        sub: t("ui.device_no_backup_days", { n: daysSince(lastBackupAt, now) }),
        right: t("ui.device_needs_attention"),
      };
    case "transferring": {
      const flow = flowConnectionText(d.flow_connection);
      if (flow) return { alert: false, dot: flow.dot, sub: flow.sub, right: backupRight };
      break;
    }
  }
  if (d.removal === "none" && d.presence === "offline" && staleHint(d.last_seen, now)) {
    return { alert: true, dot: "act", sub: t("ui.device_stale_hint"), right: backupRight };
  }
  const pres = presenceText(
    d.presence,
    d.connection,
    relativeTime(d.last_seen, now),
    humanTime(d.last_seen, now)
  );
  return { alert: false, dot: pres.dot, sub: pres.sub, right: backupRight };
}

export function overviewRows(devices, watermarks, now, maxRows = OVERVIEW_ROWS) {
  const cap = Number.isFinite(maxRows) ? Math.max(0, Math.floor(maxRows)) : OVERVIEW_ROWS;
  const active = devices.filter((d) => d.removal === "none").sort(byActivity);
  const withRow = active.map((d) => ({ d, row: deviceRow(d, watermarks[d.node_id], now) }));
  const alerts = withRow.filter((x) => x.d.needs_attention);
  const ok = withRow.filter((x) => !x.d.needs_attention);
  const shown = [...alerts, ...ok.slice(0, Math.max(0, cap - alerts.length))];
  return { shown, moreOk: ok.length - (shown.length - alerts.length) };
}
