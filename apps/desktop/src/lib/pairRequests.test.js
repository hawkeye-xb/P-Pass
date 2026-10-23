// 弹窗视图模型：一块 = 一次申请。钉住真机上遇到的两个问题。
import { describe, expect, it } from "vitest";
import { removeRequest, requestId, setPhase, syncRequests } from "./pairRequests.js";

const req = (node, at) => ({ node_id: node.repeat(64), name: "Galaxy", requested_at: at });

describe("pairRequests", () => {
  it("新申请到达：加一块，报告 added（App 据此自动弹出）", () => {
    const { rows, added } = syncRequests([], [req("a", 1)]);
    expect(rows).toHaveLength(1);
    expect(rows[0].phase).toBe("input");
    expect(added).toEqual([requestId(req("a", 1))]);
    // 同一次申请再同步一遍不算新到达。
    expect(syncRequests(rows, [req("a", 1)]).added).toEqual([]);
  });

  // 反证：块按 node_id 记 → 新申请继承 failed，红。
  it("同一台手机重新扫码 = 新申请，不带上一次的错误", () => {
    let { rows } = syncRequests([], [req("a", 1)]);
    rows = setPhase(rows, requestId(req("a", 1)), "failed");
    rows = syncRequests(rows, []).rows; // daemon 已撤掉作废的那次
    const again = syncRequests(rows, [req("a", 2)]);
    const fresh = again.rows.find((r) => r.id === requestId(req("a", 2)));
    expect(fresh.phase).toBe("input");
    expect(again.added).toEqual([requestId(req("a", 2))]);
  });

  // 反证：队列空了就删掉所有块 → 码错的提示随弹窗一起消失，红。
  it("队列先空了：等结果的、已作废的留着；只在输入阶段的随之消失", () => {
    let { rows } = syncRequests([], [req("a", 1), req("b", 1), req("c", 1)]);
    rows = setPhase(rows, requestId(req("a", 1)), "busy");
    rows = setPhase(rows, requestId(req("b", 1)), "failed");
    rows = syncRequests(rows, []).rows;
    expect(rows.map((r) => r.phase).sort()).toEqual(["busy", "failed"]);
    expect(removeRequest(rows, requestId(req("b", 1))).map((r) => r.phase)).toEqual(["busy"]);
  });
});
