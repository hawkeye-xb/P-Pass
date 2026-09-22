import { describe, expect, it } from "vitest";
import { startupFailureText } from "./daemonStartupError.js";

// 向导那条「stderr 真的流进了红条」的护栏在 `src/wizardStartupFailure.test.js`
// ——它挂载 Wizard / WizardWindows 并读渲染出来的文本。
//
// QA-16（#326）：这里原本还有一条 `readFileSync` 源码 grep 的用例，检查
// `invoke("daemon_startup_error")` 这个字符串在、`后台服务没有在 10 秒内就绪`
// 不在。它是假护栏：删掉 `Wizard.svelte` 的 `startupFailureText(stderr) ||`
// 之后字符串照样在，行为已断，测试全绿（M3 实测）。已删，不再留一个看起来
// 像"向导被测了"的东西在这里。

describe("startupFailureText", () => {
  it("keeps daemon stderr visible and explains a migration mismatch", () => {
    const stderr =
      "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";

    const text = startupFailureText(stderr);

    expect(text).toContain(stderr);
    expect(text).toContain("这个版本比你的照片库旧。请装回新版本。");
  });
});
