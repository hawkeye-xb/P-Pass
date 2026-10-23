// @vitest-environment jsdom
// 分格验证码输入的行为合同：6 格、只收数字、粘贴整串、退格回上一格、回车满位才提交。
// 反证：把组件退回单个普通文本框（无格子）→ 第一条红；去掉 digitsOnly → 第二条红。
import { cleanup, fireEvent, render } from "@testing-library/svelte";
import { afterEach, describe, expect, it, vi } from "vitest";
import InputOTP from "./input-otp.svelte";

const slotText = (c) => [...c.querySelectorAll('[data-slot="input-otp-slot"]')].map((s) => s.textContent.trim());
const activeIndex = (c) =>
  [...c.querySelectorAll('[data-slot="input-otp-slot"]')].findIndex((s) => s.hasAttribute("data-active"));

describe("InputOTP", () => {
  afterEach(cleanup);

  it("6 个格子，逐位输入自动跳到下一格", async () => {
    const { container } = render(InputOTP, { props: { "data-testid": "otp" } });
    const input = container.querySelector("input");
    expect(slotText(container)).toEqual(["", "", "", "", "", ""]);
    await fireEvent.focus(input);
    expect(activeIndex(container)).toBe(0);
    await fireEvent.input(input, { target: { value: "1" } });
    await fireEvent.input(input, { target: { value: "12" } });
    expect(slotText(container)).toEqual(["1", "2", "", "", "", ""]);
    expect(activeIndex(container)).toBe(2);
    expect(input.getAttribute("autocomplete")).toBe("one-time-code");
    expect(input.getAttribute("inputmode")).toBe("numeric");
  });

  it("粘贴「123 456」一次填满，非数字与超长部分丢掉", async () => {
    const { container } = render(InputOTP);
    const input = container.querySelector("input");
    await fireEvent.input(input, { target: { value: "123 456" } });
    expect(slotText(container)).toEqual(["1", "2", "3", "4", "5", "6"]);
    await fireEvent.input(input, { target: { value: "a98-7654321" } });
    expect(slotText(container)).toEqual(["9", "8", "7", "6", "5", "4"]);
    expect(input.value).toBe("987654");
  });

  it("退格删掉最后一位，光标回到上一格", async () => {
    const { container } = render(InputOTP);
    const input = container.querySelector("input");
    await fireEvent.focus(input);
    await fireEvent.input(input, { target: { value: "1234" } });
    expect(activeIndex(container)).toBe(4);
    await fireEvent.input(input, { target: { value: "123" } });
    expect(slotText(container)).toEqual(["1", "2", "3", "", "", ""]);
    expect(activeIndex(container)).toBe(3);
  });

  it("回车：满 6 位才调 onEnter", async () => {
    const onEnter = vi.fn();
    const { container } = render(InputOTP, { props: { onEnter } });
    const input = container.querySelector("input");
    await fireEvent.input(input, { target: { value: "12345" } });
    await fireEvent.keyDown(input, { key: "Enter" });
    expect(onEnter).not.toHaveBeenCalled();
    await fireEvent.input(input, { target: { value: "123456" } });
    await fireEvent.keyDown(input, { key: "Enter" });
    expect(onEnter).toHaveBeenCalledWith("123456");
  });
});
