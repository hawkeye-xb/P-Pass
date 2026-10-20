// #1060：更新流程的顺序——下载期间不停；下载完才暂停；暂停后才 install；
// 失败（下载 / 安装）走自愈；暂停失败不挡更新。
// 反证：把 pauseDaemon 挪回 download 之前 → 「下载期间不停」红；去掉 catch 里的
// selfHeal → 两条失败用例红；暂停不 catch → 「暂停失败不挡更新」红。
import { describe, expect, it, vi } from "vitest";
import { runUpdate } from "./updateFlow.js";
import { readFileSync } from "node:fs";

function setup({ failDownload = false, failInstall = false, failPause = false } = {}) {
  const log = [];
  const update = {
    download: async (onEvent) => {
      log.push("download:start");
      onEvent({ event: "Started", data: { contentLength: 200 } });
      onEvent({ event: "Progress", data: { chunkLength: 100 } });
      if (failDownload) throw new Error("net down");
      onEvent({ event: "Progress", data: { chunkLength: 100 } });
      onEvent({ event: "Finished" });
      log.push("download:end");
    },
    install: async () => {
      log.push("install");
      if (failInstall) throw new Error("locked");
    },
  };
  const progress = [];
  const phases = [];
  const deps = {
    update,
    pauseDaemon: async () => {
      log.push("pause");
      if (failPause) throw new Error("pause boom");
    },
    selfHeal: async () => void log.push("selfHeal"),
    onPhase: (p) => phases.push(p),
    onProgress: (p) => progress.push(p),
    warn: vi.fn(),
  };
  return { log, deps, progress, phases };
}

describe("runUpdate", () => {
  it("下载期间不停；下载完才暂停；暂停后才 install；成功不自愈", async () => {
    const { log, deps, progress, phases } = setup();
    await runUpdate(deps);
    expect(log).toEqual(["download:start", "download:end", "pause", "install"]);
    expect(phases).toEqual(["downloading", "installing"]);
    expect(progress).toEqual([0, 50, 100, 100]);
  });

  it("安装失败：走自愈并把错误抛给调用方", async () => {
    const { log, deps } = setup({ failInstall: true });
    await expect(runUpdate(deps)).rejects.toThrow("locked");
    expect(log).toEqual(["download:start", "download:end", "pause", "install", "selfHeal"]);
  });

  it("下载失败：从未暂停过，也走自愈（壳侧按用户停止标记判）", async () => {
    const { log, deps } = setup({ failDownload: true });
    await expect(runUpdate(deps)).rejects.toThrow("net down");
    expect(log).not.toContain("pause");
    expect(log).not.toContain("install");
    expect(log).toContain("selfHeal");
  });

  it("暂停失败只记日志，不挡更新", async () => {
    const { log, deps } = setup({ failPause: true });
    await runUpdate(deps);
    expect(log).toContain("install");
    expect(deps.warn).toHaveBeenCalled();
  });

  it("总长未知：进度保持 null，不编百分比", async () => {
    const { deps, progress } = setup();
    deps.update.download = async (onEvent) => {
      onEvent({ event: "Started", data: {} });
      onEvent({ event: "Progress", data: { chunkLength: 10 } });
    };
    await runUpdate(deps);
    expect(progress).toEqual([null, null]);
  });
});

describe("App.svelte 接线", () => {
  const src = readFileSync(new URL("../App.svelte", import.meta.url), "utf8");
  it("不再裸调 downloadAndInstall，也不在下载前调 pause_daemon_for_update", () => {
    expect(src).not.toContain("downloadAndInstall(");
    expect(src).toContain("runUpdate(");
    expect(src).toContain('pauseDaemon: () => invoke("pause_daemon_for_update")');
    expect(src).not.toMatch(/await invoke\("pause_daemon_for_update"\)/);
  });
});
