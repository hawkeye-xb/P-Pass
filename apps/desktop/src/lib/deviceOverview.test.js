import { describe, expect, it } from "vitest";
import { t } from "./i18n.js";
import { deviceRow, overviewRows } from "./deviceOverview.js";

const day = 24 * 60 * 60 * 1000;
const now = 30 * day;
const offline = { removal: "none", presence: "offline", last_seen: now - 16 * day };

describe("desktop device projection", () => {
  it("distinguishes unpairing, backup warnings, and stale presence", () => {
    expect(deviceRow({ ...offline, row_state: "disconnected" }, null, now).sub).toBe(t("ui.disconnected"));
    expect(deviceRow({ ...offline, row_state: "needs_attention" }, { last_backup_at: now - 6 * day }, now))
      .toMatchObject({ alert: true, sub: t("ui.device_no_backup_days", { n: 6 }) });
    expect(deviceRow(offline, null, now)).toMatchObject({ alert: true, sub: t("ui.device_stale_hint") });
  });

  it("puts active transfer ahead of stale presence and preserves the no-backup label", () => {
    expect(deviceRow({ ...offline, row_state: "transferring", flow_connection: "direct" }, null, now))
      .toEqual({ alert: false, dot: "safe", sub: t("ui.flow_direct"), right: t("ui.device_never_backed_up") });
  });

  it("keeps all backup warnings, caps healthy rows, and omits disconnected devices", () => {
    const healthy = { removal: "none", presence: "online", last_seen: now - day };
    const input = [
      { ...healthy, node_id: "ok-old", last_activity_at: 3 },
      { ...healthy, node_id: "ok-new", last_activity_at: 4 },
      { ...healthy, node_id: "warn-old", last_activity_at: 1, row_state: "needs_attention" },
      { ...healthy, node_id: "warn-new", last_activity_at: 2, row_state: "needs_attention" },
      { ...healthy, node_id: "away", last_activity_at: 5, removal: "disconnected" },
    ];
    const { shown, moreOk } = overviewRows(input, {}, now);
    expect(shown.map(({ d }) => d.node_id)).toEqual(["warn-new", "warn-old", "ok-new"]);
    expect(moreOk).toBe(1);
    expect(input[0].node_id).toBe("ok-old");

    // 动态 maxRows：缩窄高度传入 1 时仍保留全部告警设备；放宽传入 5 时展开全部健康设备
    const compact = overviewRows(input, {}, now, 1);
    expect(compact.shown.map(({ d }) => d.node_id)).toEqual(["warn-new", "warn-old"]);
    expect(compact.moreOk).toBe(2);

    const expanded = overviewRows(input, {}, now, 5);
    expect(expanded.shown.map(({ d }) => d.node_id)).toEqual([
      "warn-new",
      "warn-old",
      "ok-new",
      "ok-old",
    ]);
    expect(expanded.moreOk).toBe(0);
  });

  it("pins offline >15d devices with needs_attention=false ahead of healthy rows when maxRows=1", () => {
    const healthy = { removal: "none", presence: "online", last_seen: now - day };
    const input = [
      { ...healthy, node_id: "ok-new", last_activity_at: 4 },
      { ...healthy, node_id: "ok-old", last_activity_at: 3 },
      { ...offline, node_id: "stale-only", row_state: "idle", needs_attention: false, last_activity_at: 1 },
    ];
    const { shown, moreOk } = overviewRows(input, {}, now, 1);
    expect(shown.map(({ d }) => d.node_id)).toEqual(["stale-only"]);
    expect(shown[0].row.alert).toBe(true);
    expect(moreOk).toBe(2);
  });
});
