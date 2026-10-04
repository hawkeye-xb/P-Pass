// DESK-48 (#661)：设置页「更改照片库位置」入口**暂时隐藏**（#639 relocation 落地前）。
//
// 隐藏不得删除能力：`chooseFolder()` 与壳侧 `invoke("set_library_dir")` 必须仍在
// （Rust 侧 `desk46_library_dir_writer_is_shell_only` 也钉着这两条）。
// 判定前先剥掉 Svelte 注释——隐藏用的 `<!-- … -->` 里留着原样的那行按钮，
// 不剥注释的话「已隐藏」这条断言会被注释本身喂成假绿。
//
// 反证（PR 里跑过）：把设置页那段注释去掉、按钮放回来 ⇒ 第一条必须红。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { stripSvelteComments } from "./i18nGate.helpers.js";

const raw = readFileSync(
  fileURLToPath(new URL("./App.svelte", import.meta.url)),
  "utf8",
);
const code = stripSvelteComments(raw.replace(/\r\n/g, "\n"));

describe("DESK-48: 设置页暂时隐藏「更改照片库位置」入口", () => {
  it("设置页不再渲染更改入口（去掉隐藏改动应复红）", () => {
    expect(code).not.toContain("onclick={chooseFolder}");
    expect(code).not.toContain('t("ui.change_library")');
    expect(code).not.toContain('t("ui.library_change_hint")');
  });

  it("能力未损坏：选择函数与壳侧命令仍在", () => {
    expect(code).toContain("async function chooseFolder()");
    expect(code).toContain('invoke("set_library_dir"');
  });

  it("照片库卡片本体仍在：路径展示 + 打开照片库", () => {
    expect(code).toContain("status?.library_dir");
    expect(code).toContain('t("ui.open_library")');
    expect(code).toContain('t("ui.library")');
  });
});
