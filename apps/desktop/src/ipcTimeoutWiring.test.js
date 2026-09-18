// NET-11: 壳报回 `ipc timeout: {method} > 10s` 后，前端呈现必须走既有
// 「后台服务失联」横幅路径（online=false），不新开提示渠道。
//
// 反证：给 refresh() 的 catch 加一个 timeout 专属分支（toast/新 banner），
// 或在 call 层对 timeout 特判吞掉——下面的断言会挂。
// 注：不做注释剥离——App.svelte 的 style 段含成对 `/* */`，剥块注释会
// 连带吞掉 script 内容（photoWall.test.js 的 codeOf 只适用于无 CSS 的文件）。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8");

describe("NET-11 ipc timeout 呈现接线", () => {
  it("refresh 的失败路径统一置 online=false（失联横幅即呈现）", () => {
    // refresh() 的外层 catch：所有 daemon_call 失败（含 ipc timeout）
    // 收敛到同一个 online=false——既有 service-pill / 横幅状态。
    expect(app).toMatch(
      /async function refresh\(\) \{[\s\S]*?catch \(e\) \{\s*\n\s*online = false;/
    );
  });

  it("不新开 timeout 专属提示渠道（前端不特判 ipc timeout）", () => {
    // 全文件不许出现对 "ipc timeout" 的字符串特判——超时就是失联，走同一条路。
    expect(app).not.toContain("ipc timeout");
  });
});
