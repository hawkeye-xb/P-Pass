import { describe, expect, it } from "vitest";
import { auditText, auditWho, isVisibleAudit } from "./auditProjection.js";

describe("活动记录的用户投影", () => {
  it("按 daemon 重算的对象证据展示备份结果，不读取手机自报 final counts", () => {
    expect(
      auditText({
        kind: "flow.round.finished",
        evidenceSummary: { confirmed: 2, failed: 1, source_missing: 1 },
      }),
    ).toBe("已备份 2 张照片；1 张需处理；1 张已跳过");
  });

  it("只有一张成功时仍用同一条汇总，不生成逐照片活动", () => {
    expect(
      auditText({ kind: "flow.round.finished", evidenceSummary: { confirmed: 1 } }),
    ).toBe("已备份 1 张照片");
  });

  it("连接和内部控制事件不进入用户活动记录", () => {
    expect(isVisibleAudit({ kind: "device.connected" })).toBe(false);
    expect(isVisibleAudit({ kind: "flow.round.controlled" })).toBe(false);
    expect(isVisibleAudit({ kind: "flow.scope.changed" })).toBe(false);
    expect(isVisibleAudit({ kind: "ingest.item" })).toBe(false);
  });

  it("未知 kind 保留一条可见的安全兜底，但不把机器类型直接给用户", () => {
    const event = { kind: "future.internal.event" };
    expect(isVisibleAudit(event)).toBe(true);
    expect(auditText(event)).toBe("发生了一条未分类的活动");
  });

  it("本机和其它设备按审计合同显示身份", () => {
    expect(auditWho({}, [])).toBe("【本地】");
    expect(
      auditWho(
        { actor: "0123456789abcdef" },
        [{ node_id: "0123456789abcdef", name: "妈妈的手机" }],
      ),
    ).toBe("妈妈的手机 · #01234567");
  });
});
