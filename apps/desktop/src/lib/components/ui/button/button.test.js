// DESK-15 轻量门禁：锁定 Button 的 variant/size/tone 视觉合同——数值改动
// 必须是有意为之的一次性编辑（改这份测试），不能被无关重构悄悄带偏。
// 不追求重型像素回归（卡片验收标准明确说不需要），只锁组件对外契约。
import { describe, expect, it } from "vitest";
import { buttonVariants } from "./button.svelte";

/** 按空白切成独立 class token 再判断有没有——避免 "h-11" 被
 * "min-h-11" 这种子串误判为命中（真实踩过一次才加的）。 */
function tokens(classString) {
  return new Set(classString.split(/\s+/).filter(Boolean));
}

describe("Button 组件合同", () => {
  it("primary（默认）：44px 高，ink 底纸字——tokens.json tap-min 达标", () => {
    const cls = tokens(buttonVariants({ variant: "primary", size: "default" }));
    expect(cls.has("h-11")).toBe(true);
    expect(cls.has("bg-primary")).toBe(true);
    expect(cls.has("text-primary-foreground")).toBe(true);
    expect(cls.has("text-[15px]")).toBe(true);
  });

  it("secondary：透明底 + 1.5px 描边", () => {
    const cls = tokens(buttonVariants({ variant: "secondary", size: "default" }));
    expect(cls.has("h-11")).toBe(true);
    expect(cls.has("border-[1.5px]")).toBe(true);
    expect(cls.has("border-border-strong")).toBe(true);
    expect(cls.has("bg-transparent")).toBe(true);
  });

  it("danger：纸底红字红边——不是 shadcn 默认的红底红字", () => {
    const cls = tokens(buttonVariants({ variant: "danger", size: "default" }));
    expect(cls.has("bg-paper")).toBe(true);
    expect(cls.has("text-act")).toBe(true);
    expect(cls.has("bg-destructive/10")).toBe(false);
  });

  it("link：紧凑文字链接，不吃 44px 高度下限（本身就是文档化例外）", () => {
    const cls = tokens(buttonVariants({ variant: "link", size: "default" }));
    expect(cls.has("h-auto")).toBe(true);
    expect(cls.has("h-11")).toBe(false);
  });

  it("link tone=safe：正向次要跳转用安全绿，不是中性灰", () => {
    const cls = tokens(buttonVariants({ variant: "link", tone: "safe" }));
    expect(cls.has("text-safe")).toBe(true);
  });

  it("size=compact 是显式例外，且不覆盖 link 自己的紧凑高度", () => {
    const compactPrimary = tokens(buttonVariants({ variant: "primary", size: "compact" }));
    expect(compactPrimary.has("h-10")).toBe(true);
    expect(compactPrimary.has("h-11")).toBe(false);
  });

  it("默认 variant 是 primary，不是 shadcn 原装的 default", () => {
    const cls = tokens(buttonVariants({}));
    expect(cls.has("bg-primary")).toBe(true);
    expect(cls.has("h-11")).toBe(true);
  });
});
