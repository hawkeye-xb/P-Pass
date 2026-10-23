// NET-11: 壳报回 `ipc timeout: {method} > 10s` 后，前端呈现必须走既有的
// 服务状态通道，不新开提示渠道。
//
// DESK-63 (#946): 超时的呈现不再是 refresh() 自己写 `online=false`——那正是
// 「一次数据失败把服务判死」的旧病。超时由 Rust 的具名后台命令（daemon_api.rs 的 forward）记进
// desktop.log，服务状态由事件流（service-state）拥有。前端只渲染状态。
//
// 反证：给 refresh() 的 catch 加一个 timeout 专属分支（toast/新 banner），
// 或在 call 层对 timeout 特判吞掉——下面的断言会挂。
// 注：不做注释剥离——App.svelte 的 style 段含成对 `/* */`，剥块注释会
// 连带吞掉 script 内容（photoWall.test.js 的 codeOf 只适用于无 CSS 的文件）。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";

// 读进来先把 CRLF 归一成 LF（#297）：仓库里存的是 LF，core.autocrlf 让
// Windows 检出成 CRLF。下面那条正则里写了 `\n`，眼下它在 CRLF 下也能过
// ——但那只是因为紧邻的 `\s*` 顺手吃掉了 `\r`，是碰巧对，不是写对了。
// 谁把 `\s*` 收紧一点，红的就只有 Windows，而且看不出是行尾的事。
const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);

describe("NET-11 ipc timeout 呈现接线", () => {
  const refreshBody = app.match(/async function refresh\(\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";

  it("refresh 的失败路径不再自己判失联（状态归 Rust 的 service-state）", () => {
    // 数据刷新失败只清 status；服务状态由 Rust 事件流拥有。旧实现里
    // `online = false` 会把一次超时/一次 devices.list 失败变成「服务没运行」。
    expect(refreshBody).not.toMatch(/\bonline\s*=\s*false/);
    expect(refreshBody).not.toMatch(/\bserviceState\s*=/);
    expect(app).toContain('listen("service-state"');
  });

  it("不新开 timeout 专属提示渠道（前端不特判 ipc timeout）", () => {
    // 全文件不许出现对 "ipc timeout" 的字符串特判——超时就是失联，走同一条路。
    expect(app).not.toContain("ipc timeout");
  });
});
