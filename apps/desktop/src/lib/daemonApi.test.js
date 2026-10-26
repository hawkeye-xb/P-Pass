// #1120：前端只能调映射表里的后台方法，没有通用转发。
// 反证：callDaemon 对未知方法退回 invoke("daemon_call", …)——第一条红；
// 映射表里写一个壳没声明的命令名——第二条红。
import { readFileSync } from "node:fs";
import { beforeEach, describe, expect, it, vi } from "vitest";

const invokeMock = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({ invoke: (...a) => invokeMock(...a) }));

const { DAEMON_COMMANDS, callDaemon, daemonMethodOf } = await import("./daemonApi.js");

describe("daemonApi", () => {
  beforeEach(() => invokeMock.mockReset());

  it("未开放的方法当场拒绝，不发任何 invoke", async () => {
    await expect(callDaemon("pairing.reset", {})).rejects.toThrow("not exposed");
    await expect(callDaemon("__proto__")).rejects.toThrow("not exposed");
    expect(invokeMock).not.toHaveBeenCalled();
  });

  it("每个方法都映射到壳在 build.rs 里声明的具名命令", () => {
    const build = readFileSync(new URL("../../src-tauri/build.rs", import.meta.url), "utf8");
    for (const cmd of Object.values(DAEMON_COMMANDS)) {
      expect(build, cmd).toContain(`"${cmd}",`);
    }
  });

  it("按方法发具名命令，参数原样（snake_case）", async () => {
    invokeMock.mockResolvedValue({ ok: 1 });
    await callDaemon("device.rename", { node_id: "ab", name: "客厅" });
    expect(invokeMock).toHaveBeenCalledWith("daemon_device_rename", { node_id: "ab", name: "客厅" });
    expect(daemonMethodOf("daemon_device_rename")).toBe("device.rename");
    expect(daemonMethodOf("start_daemon")).toBeUndefined();
  });
});
