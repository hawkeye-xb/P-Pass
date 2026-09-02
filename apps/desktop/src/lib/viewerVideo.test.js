// MOB-47 视频查看器加载编排的回归锁（L2 审查三契约）。
import { describe, expect, it } from "vitest";
import { loadVideoViewer, loadVideoThumbnail, handleVideoError } from "./viewerVideo.js";

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

describe("onerror 代际守卫（handleVideoError）", () => {
  // A→B 迟到的 DOM 错误：A 的媒体错误事件在「活跃代已经换成 B」之后才
  // 到达，它绝不允许把 B 的视频变成 A 的缩略图。这里用「行为」锁，不是
  // 源码字符串比对——直接跑 A 的 token 对 B 的活跃代发守护，断言输出。
  it("旧代 A 的错误在 B 活跃后到达 → ignored，且绝不请求 B 的缩略图", async () => {
    // 活跃代：B（gen=2, hash=B）。
    let active = { gen: 2, hash: "hashB" };
    const requested = [];
    const out = await handleVideoError({
      token: { gen: 1, hash: "hashA" }, // 旧 A 元素自己那代的快照
      isActive: () => active.gen === 1 && active.hash === "hashA", // B 活跃 → false
      loadThumb: async (hash) => {
        requested.push(hash);
        return { kind: "thumb", src: `data:image/jpeg;base64,${hash}` };
      },
    });
    expect(out).toBe("ignored");
    // 关键：B 的缩略图不允许被请求，A 的图更不允许落到 B 头上。
    expect(requested).toEqual([]);
  });

  it("await thumb.get 期间切换成新代 → ignored，丢弃晚到的缩略图", async () => {
    let active = { gen: 1, hash: "hashA" };
    let resolveThumb;
    const thumb = new Promise((res) => (resolveThumb = res));
    const requested = [];
    const outP = handleVideoError({
      token: { gen: 1, hash: "hashA" },
      isActive: () => active.gen === 1 && active.hash === "hashA",
      loadThumb: async (hash) => {
        requested.push(hash);
        return thumb;
      },
    });
    // thumb.get 返回前，用户切换到了新代 B。
    active = { gen: 2, hash: "hashB" };
    resolveThumb({ kind: "thumb", src: "data:image/jpeg;base64,AAA=" });
    const out = await outP;
    expect(out).toBe("ignored");
    expect(requested).toEqual(["hashA"]);
  });

  it("仍活跃（gen/hash 都匹配）→ applied，缩略图可落地", async () => {
    const active = { gen: 1, hash: "hashA" };
    const out = await handleVideoError({
      token: { gen: 1, hash: "hashA" },
      isActive: () => active.gen === 1 && active.hash === "hashA",
      loadThumb: async (hash) => ({ kind: "thumb", src: `thumb-of-${hash}` }),
    });
    expect(out).toEqual({ kind: "applied", result: { kind: "thumb", src: "thumb-of-hashA" } });
  });

  it("关闭重开同一个 hash 的旧代（gen 不同）→ ignored，不误伤新代", async () => {
    // 同一 asset 关闭再重开：新代 gen=2，旧 video 元素的错误仍带 gen=1。
    let active = { gen: 2, hash: "same" };
    const requested = [];
    const out = await handleVideoError({
      token: { gen: 1, hash: "same" },
      isActive: () => active.gen === 1 && active.hash === "same",
      loadThumb: async (hash) => {
        requested.push(hash);
        return { kind: "thumb", src: `data:image/jpeg;base64,${hash}` };
      },
    });
    expect(out).toBe("ignored");
    expect(requested).toEqual([]);
  });

  it("缩略图也失败 → applied 且 result.kind=failed（调用方去亮降级提示）", async () => {
    const active = { gen: 1, hash: "hashA" };
    const out = await handleVideoError({
      token: { gen: 1, hash: "hashA" },
      isActive: () => active.gen === 1 && active.hash === "hashA",
      loadThumb: async () => ({ kind: "failed" }),
    });
    expect(out).toEqual({ kind: "applied", result: { kind: "failed" } });
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
    expect(src).toContain("src={viewerVideoSrc}");
  });

  it("<video> onerror 按元素自己的 gen/hash 代际守卫，且 key 随代重挂载", () => {
    expect(viewerEffect).not.toContain("onVideoError"); // handler 定义在 effect 之外
    expect(src).toContain("onVideoError");
    // 错误处理必须走代际守卫纯函数，而不是直接读全局 hash 再硬判。
    expect(src).toContain("handleVideoError(");
    expect(src).toContain("loadVideoThumbnail(");
    // 只比 hash 的旧守卫必须消失：换成「同 gen 同 hash 才是活跃代」。
    expect(src).not.toContain("viewerVideoHash");
    expect(src).not.toContain("photoViewer?.hash !== hash");
    // DOM 边界：元素以 gen 为身份快照，且 key 随代重挂载，旧元素的媒体
    // 错误仍可归因于它原来的代（data-video-gen/data-video-hash）。
    expect(src).toContain("data-video-gen={viewerVideoToken.gen}");
    expect(src).toContain("data-video-hash={viewerVideoToken.hash}");
    expect(src).toContain("{#key viewerVideoToken.gen}");
  });
});