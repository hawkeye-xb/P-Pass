// #1054：data URL 的类型取 daemon 真实 media_type；<img> 加载失败回退缩略图。
import { describe, expect, it } from "vitest";
import { originalDataUrl, loadImageViewer, handleImageError } from "./viewerImage.js";

describe("originalDataUrl", () => {
  it.each(["image/jpeg", "image/png", "image/gif", "image/webp"])("%s 按真实类型组装", (mt) => {
    expect(originalDataUrl({ media_type: mt, data_base64: "QUJD" })).toBe(`data:${mt};base64,QUJD`);
  });
  it("缺失或不在白名单（旧 daemon / 异常值）按 jpeg，且不把任意字符串拼进 URL", () => {
    expect(originalDataUrl({ data_base64: "QUJD" })).toBe("data:image/jpeg;base64,QUJD");
    expect(originalDataUrl({ media_type: "image/heic", data_base64: "QUJD" })).toBe(
      "data:image/jpeg;base64,QUJD"
    );
    expect(originalDataUrl({ media_type: "text/html;x=1", data_base64: "QUJD" })).toBe(
      "data:image/jpeg;base64,QUJD"
    );
  });
});

describe("loadImageViewer", () => {
  const live = () => false;
  it("png 原图用 data:image/png，而不是写死 jpeg", async () => {
    const call = async () => ({ media_type: "image/png", data_base64: "QUJD" });
    expect(await loadImageViewer({ call, isCancelled: live }, { hash: "h" })).toEqual({
      kind: "original",
      src: "data:image/png;base64,QUJD",
    });
  });
  it("asset.original NotFound（HEIC/RAW）→ 回退 1024 缩略图", async () => {
    const seen = [];
    const call = async (m, p) => {
      seen.push([m, p]);
      if (m === "asset.original") throw new Error("not found");
      return { jpeg_base64: "VEhVTUI=" };
    };
    expect(await loadImageViewer({ call, isCancelled: live }, { hash: "h" })).toEqual({
      kind: "thumb",
      src: "data:image/jpeg;base64,VEhVTUI=",
    });
    expect(seen[1]).toEqual(["thumb.get", { hash: "h", size: 1024 }]);
  });
  it("缩略图也失败 → failed", async () => {
    const call = async () => {
      throw new Error("x");
    };
    expect(await loadImageViewer({ call, isCancelled: live }, { hash: "h" })).toEqual({ kind: "failed" });
  });
});

describe("handleImageError（<img> onerror）", () => {
  const thumbCall = async () => ({ jpeg_base64: "VEhVTUI=" });
  it("原图解不了 → 回退缩略图", async () => {
    const r = await handleImageError({ call: thumbCall, hash: "h", showingOriginal: true, isActive: () => true });
    expect(r).toEqual({ kind: "thumb", src: "data:image/jpeg;base64,VEhVTUI=" });
  });
  it("缩略图本身出错 → failed，不再循环请求", async () => {
    let calls = 0;
    const call = async () => {
      calls += 1;
      return { jpeg_base64: "x" };
    };
    const r = await handleImageError({ call, hash: "h", showingOriginal: false, isActive: () => true });
    expect(r).toEqual({ kind: "failed" });
    expect(calls).toBe(0);
  });
  it("viewer 已关闭/换人 → 忽略迟到错误", async () => {
    const r = await handleImageError({ call: thumbCall, hash: "h", showingOriginal: true, isActive: () => false });
    expect(r).toEqual({ kind: "ignored" });
  });
});
