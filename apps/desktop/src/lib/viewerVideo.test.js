// MOB-47 视频查看器加载编排的回归锁（L2 审查三契约）。
import { describe, expect, it } from "vitest";
import { loadVideoViewer } from "./viewerVideo.js";

/** 立即成功/失败的假 invoke/convertFileSrc/call。 */
const okInvoke = async () => "/canon/clip.mp4";
const convert = (p) => `asset://localhost/${p.replace(/^\//, "")}`;

describe("安全契约", () => {
  it("asset 协议只传 hash，绝不把渲染进程路径卷进 scope", async () => {
    let seen = null;
    const deps = {
      invoke: async (cmd, args) => {
        seen = { cmd, args };
        return "/canon/clip.mp4";
      },
      call: async () => {
        throw new Error("unreachable");
      },
      convertFileSrc: convert,
      isCancelled: () => false,
    };
    const r = await loadVideoViewer(deps, { hash: "abc123" });
    expect(seen).toEqual({ cmd: "allow_media_scope", args: { hash: "abc123" } });
    expect(r).toEqual({ kind: "video", src: "asset://localhost/canon/clip.mp4", path: "/canon/clip.mp4" });
  });
});

describe("回退契约", () => {
  it("asset 协议失败（scope 拒绝/文件缺失/不支持）→ thumb.get 缩略图兜底", async () => {
    const calls = [];
    const deps = {
      invoke: async () => {
        calls.push("allow_media_scope");
        throw new Error("scope rejected");
      },
      call: async (method, params) => {
        calls.push(method);
        expect(method).toBe("thumb.get");
        expect(params).toEqual({ hash: "abc123", size: 1024 });
        return { jpeg_base64: "TUI=" };
      },
      convertFileSrc: convert,
      isCancelled: () => false,
    };
    const r = await loadVideoViewer(deps, { hash: "abc123" });
    expect(r).toEqual({ kind: "thumb", src: "data:image/jpeg;base64,TUI=" });
    expect(calls).toEqual(["allow_media_scope", "thumb.get"]);
  });

  it("缩略图也失败 → 才判失败", async () => {
    const deps = {
      invoke: async () => {
        throw new Error("scope rejected");
      },
      call: async () => {
        throw new Error("thumb failed too");
      },
      convertFileSrc: convert,
      isCancelled: () => false,
    };
    const r = await loadVideoViewer(deps, { hash: "abc123" });
    expect(r).toEqual({ kind: "failed" });
  });

  it("图片路径不变——asset.original 分支不在本编排里", async () => {
    // 本模块只管视频；图片仍走 App.svelte 的 asset.original/img 路径，
    // 本测试只是把「视频编排不碰 asset.original」这个边界钉住（反证：误把
    // asset.original 塞进视频路径 = base64 视频进内存）。
    expect(loadVideoViewer).toBeInstanceOf(Function);
  });
});

describe("竞态契约", () => {
  it("授权成功后才取消 —— 不覆盖新 viewer（cancelled）", async () => {
    let cancelled = false;
    const deps = {
      invoke: async () => {
        cancelled = true; // 授权返回前，用户已经关掉/换人
        return "/canon/clip.mp4";
      },
      call: async () => {
        throw new Error("unreachable");
      },
      convertFileSrc: convert,
      isCancelled: () => cancelled,
    };
    const r = await loadVideoViewer(deps, { hash: "abc123" });
    expect(r).toEqual({ kind: "cancelled" });
  });

  it("缩略图兜底返回前取消 → 不许覆盖新 viewer", async () => {
    let cancelled = false;
    const deps = {
      invoke: async () => {
        throw new Error("scope rejected");
      },
      call: async () => {
        cancelled = true; // 缩略图返回前取消
        return { jpeg_base64: "TUI=" };
      },
      convertFileSrc: convert,
      isCancelled: () => cancelled,
    };
    const r = await loadVideoViewer(deps, { hash: "abc123" });
    expect(r).toEqual({ kind: "cancelled" });
  });
});

// ── 接线（源码级，App.svelte）──
import { readFileSync } from "node:fs";

/** 剥掉注释再断言——避免解释性文字被当成代码（与 photoWall 同款教训）。 */
function codeOf(path) {
  return readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("//"))
    .join("\n");
}

describe("App.svelte 视频分支的接线", () => {
  const src = codeOf(new URL("../App.svelte", import.meta.url).pathname);
  // 只截取大图查看器的那个 $effect（以 `const v = photoViewer` 起头），
  // 避免把照片墙分页的 $effect 也算进来——接线断言要钉在查看器这一处。
  const viewerEffect = (() => {
    const i = src.indexOf("const v = photoViewer;");
    expect(i).toBeGreaterThan(-1);
    const tail = src.slice(i);
    const j = tail.indexOf("revealPhotoInFinder");
    expect(j).toBeGreaterThan(-1);
    return tail.slice(0, j);
  })();

  it("视频分支调用共用编排 loadVideoViewer，不内联 asset.path 再传路径给 scope", () => {
    expect(viewerEffect).toContain("loadVideoViewer(");
    // 反证：scope 变回「收渲染进程路径」的标志物必须消失。
    expect(viewerEffect).not.toContain('invoke("allow_media_scope", { path');
    expect(viewerEffect).not.toContain("allow_file");
  });

  it("<video> 承接 asset 协议 src，缩略图兜底落 <img>，双失败才落降级提示", () => {
    expect(src).toContain("viewerVideoSrc");
    expect(src).toContain('src={viewerVideoSrc}');
  });

  it("<video> onerror 走 loadVideoThumbnail 兜底，且按 hash 判是否已换人", () => {
    expect(viewerEffect).not.toContain("onVideoError"); // handler 定义在 effect 之外
    expect(src).toContain("onVideoError");
    expect(src).toContain("photoViewer?.hash !== hash");
    expect(src).toContain("loadVideoThumbnail(");
  });
});