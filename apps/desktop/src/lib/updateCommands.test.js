// #1121：更新下载 / 安装走壳的具名命令，带上界面展示的版本号。
// 反证：verifiedUpdate 退回调插件 Update 的 download / install——invoke 断言红。
import { beforeEach, describe, expect, it, vi } from "vitest";

const invokeMock = vi.fn();
class FakeChannel {
  onmessage = null;
}
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a) => invokeMock(...a), Channel: FakeChannel }));

const { verifiedUpdate } = await import("./updateCommands.js");

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
