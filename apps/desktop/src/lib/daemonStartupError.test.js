import { describe, expect, it } from "vitest";
import { startupFailureText } from "./daemonStartupError.js";
import { setLocale } from "./i18n.js";

// I18N-03 (#492)：文案搬进字典后按系统语言取词；这里断言的是中文原文——
// 只搬字不改措辞，zh 下渲染结果必须和搬迁前逐字相同。
setLocale("zh");

// 向导那条「stderr 真的流进了红条」的护栏在 `src/wizardStartupFailure.test.js`
// ——它挂载 Wizard / WizardWindows 并读渲染出来的文本。
//
// QA-16（#326）：这里原本还有一条 `readFileSync` 源码 grep 的用例，检查
// `invoke("daemon_startup_error")` 这个字符串在、`后台服务没有在 10 秒内就绪`
// 不在。它是假护栏：删掉 `Wizard.svelte` 的 `startupFailureText(stderr) ||`
// 之后字符串照样在，行为已断，测试全绿（M3 实测）。已删，不再留一个看起来
// 像"向导被测了"的东西在这里。

describe("startupFailureText", () => {
  it("daemon 认出的原因给人话，stderr 原文照常透出", () => {
    const detail =
      "migration: migration 12 was previously applied but is missing in the resolved migrations";

    const text = startupFailureText({ key: "ui.startup_migration_guidance", detail });

    expect(text).toContain(detail);
    expect(text).toContain("这个版本比你的照片库旧。请装回新版本。");
  });

  it("#1044：没有 key 就不猜——即使原文看起来像 migration 报错", () => {
    const detail =
      "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
    expect(startupFailureText({ key: null, detail })).toBe(detail);
    expect(startupFailureText(null)).toBe("");
  });
});
