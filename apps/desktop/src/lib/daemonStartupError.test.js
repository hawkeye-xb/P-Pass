import { describe, expect, it, vi } from "vitest";
import { startupFailureKey } from "./daemonStartupError.js";

// 向导那条「daemon 起不来时红条说什么」的护栏在 `src/wizardStartupFailure.test.js`
// ——它挂载 Wizard / WizardWindows 并读渲染出来的文本。
//
// QA-16（#326）：这里原本还有一条 `readFileSync` 源码 grep 的用例，检查
// `invoke("daemon_startup_error")` 这个字符串在、`后台服务没有在 10 秒内就绪`
// 不在。它是假护栏：删掉向导里读 stderr 的那一步之后字符串照样在，行为已断，
// 测试全绿（M3 实测）。已删，不再留一个看起来像"向导被测了"的东西在这里。
//
// B13：stderr 原文只进 console，不进界面；红条只用 daemon 认出的原因 key。

describe("startupFailureKey", () => {
  it("daemon 认出的原因给 key，stderr 原文只进 console", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const detail =
        "migration: migration 12 was previously applied but is missing in the resolved migrations";
      expect(startupFailureKey({ key: "ui.startup_migration_guidance", detail })).toBe(
        "ui.startup_migration_guidance",
      );
      expect(warn).toHaveBeenCalledWith(expect.any(String), detail);
    } finally {
      warn.mockRestore();
    }
  });

  it("#1044：没有 key 就不猜——即使原文看起来像 migration 报错；未登记的 key 也不用", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const detail =
        "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";
      expect(startupFailureKey({ key: null, detail })).toBeNull();
      expect(startupFailureKey({ key: "ui.never_registered", detail })).toBeNull();
      expect(startupFailureKey(null)).toBeNull();
    } finally {
      warn.mockRestore();
    }
  });
});
