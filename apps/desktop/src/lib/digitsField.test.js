// @vitest-environment jsdom
// 反证：去掉 paste 处理、靠 maxlength 截 → 「12a3 45-6」只剩 1234，红；不就地改写 → 字母留在框里，红。
import { describe, expect, it } from "vitest";
import { onDigitsInput, onDigitsPaste } from "./digitsField.js";

function field(value, caret = value.length, end = caret) {
  const el = document.createElement("input");
  el.value = value;
  el.setSelectionRange(caret, end);
  return el;
}

describe("验证码输入框", () => {
  it("非数字直接过滤，光标不跳到末尾", () => {
    const el = field("12a34", 3); // 在 2 后敲了 a
    expect(onDigitsInput(el)).toBe("1234");
    expect(el.value).toBe("1234");
    expect(el.selectionStart).toBe(2);
  });

  it("中间改一位：光标留在改的位置", () => {
    const el = field("129456", 3);
    expect(onDigitsInput(el)).toBe("129456");
    expect(el.selectionStart).toBe(3);
  });

  it("粘贴「12a3 45-6」得到 123456", () => {
    const el = field("");
    expect(onDigitsPaste(el, "12a3 45-6")).toBe("123456");
    expect(el.value).toBe("123456");
  });

  it("粘贴插在选区处、替换选中部分，超长截到 6 位", () => {
    const el = field("1299", 2, 4); // 选中「99」
    expect(onDigitsPaste(el, "3-4-5-6-7")).toBe("123456");
    expect(el.selectionStart).toBe(6);
  });
});
