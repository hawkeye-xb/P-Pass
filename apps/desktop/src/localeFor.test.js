// #1045：语言读不到时一律英文。平台层（托盘 / 安装位置对话框，B6 #1043）早就是
// 「zh* → zh，其它和读不到 → en」；前端原先对空串返回 zh，两层口径不一致。
//
// 反证：把 localeFor 的空值分支改回 "zh"，第一条必须红。
import { describe, expect, it } from "vitest";

import { localeFor } from "./lib/i18n.js";

describe("localeFor", () => {
  it("empty or missing language is English, same as the platform layer", () => {
    for (const v of ["", undefined, null]) expect(localeFor(v)).toBe("en");
  });

  it("only zh* is Chinese", () => {
    for (const v of ["zh", "zh-CN", "zh-Hans", "ZH-tw"]) expect(localeFor(v)).toBe("zh");
    for (const v of ["en", "en-US", "ja", "fr-FR"]) expect(localeFor(v)).toBe("en");
  });
});
