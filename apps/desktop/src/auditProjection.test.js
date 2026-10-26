import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { auditText, auditWho } from "./auditProjection.js";
import { setLocale } from "./lib/i18n.js";

// I18N-03 (#492)：文案搬进字典后按系统语言取词；这里断言的是中文原文——
// 只搬字不改措辞，zh 下渲染结果必须和搬迁前逐字相同。
setLocale("zh");

describe("活动记录的用户投影", () => {
  it("按 daemon 分好类的每轮计数展示备份结果（不自己再算一遍）", () => {
    expect(
      auditText({
        kind: "flow.round.finished",
        counts: { backedUp: 2, needsAttention: 1, skipped: 1 },
      }),
    ).toBe("已备份 2 张照片；1 张需处理；1 张已跳过");
  });

  it("只有一张成功时仍用同一条汇总，不生成逐照片活动", () => {
    expect(
      auditText({ kind: "flow.round.finished", counts: { backedUp: 1, needsAttention: 0, skipped: 0 } }),
    ).toBe("已备份 1 张照片");
  });

  it("未知 kind 出安全兜底文案，但不把机器类型直接给用户", () => {
    expect(auditText({ kind: "future.internal.event" })).toBe("发生了一条未分类的活动");
  });

  it("#1044：daemon 列为「有文案」的每个 kind，桌面字典里都真有一条（不落兜底）", () => {
    const src = readFileSync(
      new URL("../../../crates/daemon/src/audit_projection.rs", import.meta.url),
      "utf8",
    );
    const block = src.match(/pub const USER_KINDS_WITH_COPY: &\[&str\] = &\[([\s\S]*?)\];/);
    expect(block).not.toBeNull();
    const kinds = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
    expect(kinds.length).toBeGreaterThan(5);
    const fallback = auditText({ kind: "future.internal.event" });
    for (const kind of kinds) {
      expect(auditText({ kind, payload: {}, counts: {} }), kind).not.toBe(fallback);
    }
  });

  it("#552：配对未成的三种结局各有各的文案，不落入未分类兜底", () => {
    const denied = auditText({ kind: "pair.denied" });
    const cancelled = auditText({ kind: "pair.cancelled" });
    const expired = auditText({ kind: "pair.expired" });
    // #1118：业主输错验证码，这次申请作废。
    const codeFailed = auditText({ kind: "pair.code_failed" });
    expect(denied).toBe("加入被拒绝");
    expect(cancelled).toBe("手机已取消");
    expect(expired).toBe("配对已超时");
    expect(codeFailed).toBe("验证码不对，未加入");
    const unknown = auditText({ kind: "future.internal.event" });
    for (const text of [denied, cancelled, expired, codeFailed]) expect(text).not.toBe(unknown);
    expect(new Set([denied, cancelled, expired, codeFailed]).size).toBe(4);
    for (const kind of ["pair.denied", "pair.cancelled", "pair.expired", "pair.code_failed"]) {
      expect(auditWho({ kind, payload: { deviceName: "客厅的手机" } }, [])).toBe("客厅的手机");
    }
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
