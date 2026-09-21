// DEV-06: 配对结果 toast 的名字，来源必须是设备表，不是手机自报名。
//
// 真机实测（#349 第二条评论）：同一屏上「已允许 SM-S9210 加入」与活动记录
// 的「客厅的手机 已加入」并排出现——同一事件两个名字。弹窗标题和活动记录
// 都对，错的只有 `confirmPair` 里那一行 toast，它用了 `pairing.confirm` 回
// 的 `r.device`。那个字段就是队列里的自报名（crates/daemon/src/ipc.rs:1155
// `let name = p.device_name.clone()`），永远不会是业主改过的称呼。
//
// 正确来源是 `pairing.pending` 那一行的 `name`：daemon 已经按 DEV-04 的口径
// 解析过了（ipc.rs:1189-1193，known 时取 device 表的 name，否则自报名），
// 弹窗标题正因为用它才是对的。
//
// 反证：把 pairResultName 改回 `resp.device` 优先，或让 App.svelte 那行退回
// `{ name: r.device }`——下面的断言会挂。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { pairResultName } from "./lib/pending.js";
import zhDict from "../../../assets/i18n/zh.json";

/** App.svelte 里那个 t() 的等价物——断言的是**渲染出来的整句**，不是参数。 */
const t = (key, vars = {}) => {
  let s = zhDict[key] ?? key;
  for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
  return s;
};

// 业主在桌面改过名的老设备重连：队列行带桌面名，daemon 回的是自报名。
const renamed = {
  node_id: "b".repeat(64),
  known: true,
  name: "客厅的手机",
  paired_at: 1_700_000_000_000,
  revoked: false,
  photo_count: 1,
};
const renamedResp = { decided: true, device: "SM-S9210" };

// 首次配对：设备表里还没有这一行，daemon 两边都给自报名。
const firstTime = { node_id: "a".repeat(64), known: false, name: "SM-S9210" };
const firstTimeResp = { decided: true, device: "SM-S9210" };

describe("DEV-06 配对结果提示的名字来源", () => {
  it("改过名的设备重连：允许的提示说业主改的名字，不是手机自报名", () => {
    const name = pairResultName(renamed, renamedResp);
    expect(t("ui.pair_allowed", { name })).toBe("已允许「客厅的手机」加入");
    expect(t("ui.pair_allowed", { name })).not.toContain("SM-S9210");
  });

  it("拒绝分支同一口径", () => {
    const name = pairResultName(renamed, { decided: false, device: "SM-S9210" });
    expect(t("ui.pair_denied", { name })).toBe("已拒绝「客厅的手机」");
    expect(t("ui.pair_denied", { name })).not.toContain("SM-S9210");
  });

  it("首次配对：设备表里没有这一行，仍显示自报名，不退化成 id 或空", () => {
    const name = pairResultName(firstTime, firstTimeResp);
    expect(name).toBe("SM-S9210");
    expect(t("ui.pair_allowed", { name })).toBe("已允许「SM-S9210」加入");
    // 不许拿 node_id 顶名字用。
    expect(name).not.toContain("a".repeat(8));
  });

  it("横幅那条路不带 item（App.svelte:1265-1266 老调用方）：回退 daemon 回的名字", () => {
    // 队首语义——daemon 自己挑的那台，前端手上没有对应的 pending 行。
    expect(pairResultName(undefined, renamedResp)).toBe("SM-S9210");
    expect(pairResultName(null, { device: "SM-S9210" })).toBe("SM-S9210");
    // 老 daemon 的 pending 只有字符串，normalize 成 { name }——照样能用。
    expect(pairResultName({ name: "SM-S9210" }, {})).toBe("SM-S9210");
  });

  it("脏输入不炸、不渲染出 undefined", () => {
    expect(pairResultName(null, null)).toBe("");
    expect(pairResultName({ name: "  " }, { device: "SM-S9210" })).toBe("SM-S9210");
    expect(pairResultName({}, {})).toBe("");
  });
});

// ── 接线与回归护栏：断言的是 App.svelte 这一个文件的源码 ──────────────
const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);

describe("DEV-06 接线", () => {
  it("confirmPair 的 toast 走 pairResultName(item, r)，不再直接用 r.device", () => {
    const fn = app.slice(
      app.indexOf("async function confirmPair("),
      app.indexOf("async function revoke(")
    );
    expect(fn).toContain("pairResultName(item, r)");
    expect(fn).not.toContain("{ name: r.device }");
    expect(app).toContain("pairResultName");
  });

  it("回归护栏：活动记录三行的名字渲染不动（仍是 auditWho(e, devices)）", () => {
    // 真机实测这三行是对的（#349 第二条评论）——本卡不许把它们改坏。
    const hits = app.match(/auditWho\(e, devices\)/g) ?? [];
    expect(hits.length).toBe(2); // 总览页 + 活动记录页两个渲染点
    expect(app).toContain(
      'import { auditText, auditWho, isVisibleAudit } from "./auditProjection.js"'
    );
  });
});
