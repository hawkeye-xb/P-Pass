// #1121：更新下载 / 安装走壳的具名命令，带上界面展示的版本号。
// 反证：verifiedUpdate 退回调插件 Update 的 download / install——invoke 断言红。
import { beforeEach, describe, expect, it, vi } from "vitest";

const invokeMock = vi.fn();
class FakeChannel {
  onmessage = null;
}
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a) => invokeMock(...a), Channel: FakeChannel }));

const { verifiedUpdate, UPDATE_CHECK_TIMEOUT_MS } = await import("./updateCommands.js");

describe("verifiedUpdate", () => {
  beforeEach(() => invokeMock.mockReset());

  it("download 调 update_download，带期望版本与进度通道", async () => {
    invokeMock.mockResolvedValue(undefined);
    const events = [];
    await verifiedUpdate({ version: "1.2.3" }).download((e) => events.push(e));
    const [cmd, args] = invokeMock.mock.calls[0];
    expect(cmd).toBe("update_download");
    expect(args.expected_version).toBe("1.2.3");
    args.on_event.onmessage({ event: "Finished" });
    expect(events).toEqual([{ event: "Finished" }]);
  });

  it("install 调 update_install（不带任何字节，安装的是壳里校验过的那份）", async () => {
    invokeMock.mockResolvedValue(undefined);
    await verifiedUpdate({ version: "1.2.3" }).install();
    expect(invokeMock).toHaveBeenCalledWith("update_install");
  });
});

// #1151：网页发起的「检查更新」必须带总时长上限。反证：App.svelte 退回无参 checkUpdate() ⇒ 红。
describe("检查更新带超时（#1151）", () => {
  it("上限是几十秒量级", () => {
    expect(UPDATE_CHECK_TIMEOUT_MS).toBeGreaterThanOrEqual(5_000);
    expect(UPDATE_CHECK_TIMEOUT_MS).toBeLessThanOrEqual(120_000);
  });

  it("App.svelte 里每一处 checkUpdate 调用都带 timeout", async () => {
    const { readFileSync } = await import("node:fs");
    const src = readFileSync(new URL("../App.svelte", import.meta.url), "utf8");
    const calls = src.match(/checkUpdate\(([^)]*)\)/g) ?? [];
    expect(calls.length).toBeGreaterThan(0);
    for (const c of calls) expect(c).toContain("timeout: UPDATE_CHECK_TIMEOUT_MS");
  });
});
