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
  it("揭示整件事交给壳：前端不取路径、不拼路径", async () => {
    const reveal = vi.fn().mockResolvedValue(undefined);
    await openLibraryDir({ reveal });
    expect(reveal).toHaveBeenCalledTimes(1);
    expect(reveal).toHaveBeenCalledWith();
  });

  it("壳揭示失败（IPC 不可达等原文）：归一成 keyed 文案，不透出原文", async () => {
    const raw = "连接后台服务失败: Connection refused (os error 61) /x/ipc.token";
    for (const fail of [
      () => Promise.reject(raw),
      () => Promise.reject(new Error("ENOENT /gone")),
    ]) {
      const e = await openLibraryDir({ reveal: fail }).catch((x) => x);
      expect(e.key).toBe("ui.library_dir_unknown");
      const text = errText(e);
      expect(text).not.toContain("Connection refused");
      expect(text).not.toContain("ipc.token");
      expect(text).not.toContain("ENOENT");
    }
  });

  it("壳给的 keyed 错误（JSON 串）原样保留", async () => {
    const wire = JSON.stringify({ key: "ui.library_dir_unknown", params: {} });
    const e = await openLibraryDir({ reveal: () => Promise.reject(wire) }).catch((x) => x);
    expect(e.key).toBe("ui.library_dir_unknown");
  });

  it("App 接线：openLibrary 走 reveal_library 命令（路径不经网页），不再调 status、不拼 originals", () => {
    const src = readFileSync(new URL("../App.svelte", import.meta.url), "utf8");
    const body = src.slice(src.indexOf("async function openLibrary()"), src.indexOf("async function openDeviceFolder"));
    expect(body).toContain('invoke("reveal_library")');
    expect(body).not.toContain("/originals");
    expect(body).not.toContain('call("status")');
  });
});
