// DESK-15 轻量门禁：锁定 Card 的 size/variant 视觉合同——同款教训见
// ui/button/button.test.js（子串匹配会被 min-h-11 之类误判，这里直接按
// token 精确比对）。
import { describe, expect, it } from "vitest";
import { cardVariants } from "./card.svelte";

function tokens(classString) {
  return new Set(classString.split(/\s+/).filter(Boolean));
}

describe("Card 组件合同", () => {
  it("default：22px/20px 内边距、border-border、无阴影无 ring", () => {
    const cls = tokens(cardVariants({ size: "default", variant: "default" }));
    expect(cls.has("px-[22px]")).toBe(true);
    expect(cls.has("py-5")).toBe(true);
    expect(cls.has("border-border")).toBe(true);
    expect(cls.has("shadow-none")).toBe(true);
    expect(cls.has("ring-0")).toBe(true);
    expect(cls.has("p-0")).toBe(false);
  });

  it("flush：零内边距，给自带滚动的列表卡用", () => {
    const cls = tokens(cardVariants({ size: "flush" }));
    expect(cls.has("p-0")).toBe(true);
    expect(cls.has("px-[22px]")).toBe(false);
  });

  it("danger：红边红底，不是默认的 border-border/bg-card", () => {
    const cls = tokens(cardVariants({ variant: "danger" }));
    expect(cls.has("border-act")).toBe(true);
    expect(cls.has("bg-act-bg")).toBe(true);
    expect(cls.has("border-border")).toBe(false);
  });

  it("不传参数时默认 default/default（跟组件 $props 默认值一致）", () => {
    const cls = tokens(cardVariants());
    expect(cls.has("px-[22px]")).toBe(true);
    expect(cls.has("border-border")).toBe(true);
  });
});
