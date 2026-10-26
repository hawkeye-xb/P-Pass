// #1059：服务停止（IPC 不可达）时「打开照片库」照样取到目录并揭示；
// 取不到/揭示不了时只给 keyed 文案，不透出 IPC 原文。
// #1066 反证：reveal 前再拼 `${path}/originals` → 第一条红。
// 反证：openLibraryDir 改回先 call("status")（getPath 抛 Connection refused）→ 第一条红；
// 去掉 catch 归一 → 第二、三条红（原文透出）。
import { describe, expect, it, vi } from "vitest";
import { openLibraryDir } from "./openLibrary.js";
import { errText } from "./i18n.js";
import { readFileSync } from "node:fs";

describe("openLibraryDir", () => {
  it("取路径不经后台服务：原样揭示壳给的完整路径，前端不拼", async () => {
    const reveal = vi.fn().mockResolvedValue(undefined);
    await openLibraryDir({ getPath: async () => "C:\\lib\\originals", reveal });
    expect(reveal).toHaveBeenCalledTimes(1);
    expect(reveal).toHaveBeenCalledWith("C:\\lib\\originals");
  });

  it("读不到库目录：keyed 文案，不透出原文", async () => {
    const raw = "连接后台服务失败: Connection refused (os error 61) /x/ipc.token";
    for (const getPath of [
      async () => {
        throw raw;
      },
      async () => "",
    ]) {
      const e = await openLibraryDir({ getPath, reveal: vi.fn() }).catch((x) => x);
      expect(e.key).toBe("ui.library_dir_unknown");
      const text = errText(e);
      expect(text).not.toContain("Connection refused");
      expect(text).not.toContain("ipc.token");
    }
  });

  it("壳给的 keyed 错误（JSON 串）原样保留", async () => {
    const wire = JSON.stringify({ key: "ui.library_dir_unknown", params: {} });
    const e = await openLibraryDir({
      getPath: async () => {
        throw wire;
      },
      reveal: vi.fn(),
    }).catch((x) => x);
    expect(e.key).toBe("ui.library_dir_unknown");
  });

  it("目录揭示失败也是 keyed，不透出系统原文", async () => {
    const e = await openLibraryDir({
      getPath: async () => "/gone",
      reveal: vi.fn().mockRejectedValue(new Error("ENOENT /gone")),
    }).catch((x) => x);
    expect(errText(e)).not.toContain("ENOENT");
  });

  it("App 接线：openLibrary 走 library_reveal_path 命令，不再调 status、不拼 originals", () => {
    const src = readFileSync(new URL("../App.svelte", import.meta.url), "utf8");
    const body = src.slice(src.indexOf("async function openLibrary()"), src.indexOf("async function openDeviceFolder"));
    expect(body).toContain('invoke("library_reveal_path")');
    expect(body).not.toContain("/originals");
    expect(body).not.toContain('call("status")');
  });
});
