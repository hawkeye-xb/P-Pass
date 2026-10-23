// 验证码输入框：只收数字、最多 N 位，光标留在原处（普通输入框的标准交互，可在任意位置改）。
//
// 不能只靠 bind:value 回写过滤结果：过滤后值没变（比如在「12」里敲了个字母）时框架不会
// 重写 DOM，字母会留在框里。也不能靠 maxlength 截粘贴：浏览器会先按长度截「12a3 45-6」
// 成「12a3 4」再给我们，数字就丢了。所以输入、粘贴都在这里就地改写 input。

/** 只留数字，最多 `max` 位。 */
export function digitsOnly(raw, max) {
  return String(raw ?? "").replace(/[^0-9]/g, "").slice(0, max);
}

function rewrite(el, raw, caret, max) {
  const next = digitsOnly(raw, max);
  const pos = Math.min(digitsOnly(raw.slice(0, caret), max).length, next.length);
  el.value = next;
  el.setSelectionRange(pos, pos);
  return next;
}

/** input 事件：就地过滤，返回过滤后的值。 */
export function onDigitsInput(el, max = 6) {
  return rewrite(el, el.value, el.selectionStart ?? el.value.length, max);
}

/** paste 事件：只把剪贴板里的数字插到选区处，返回过滤后的值。调用方先 preventDefault。 */
export function onDigitsPaste(el, text, max = 6) {
  const start = el.selectionStart ?? el.value.length;
  const end = el.selectionEnd ?? start;
  const ins = digitsOnly(text, max);
  const raw = el.value.slice(0, start) + ins + el.value.slice(end);
  return rewrite(el, raw, start + ins.length, max);
}
