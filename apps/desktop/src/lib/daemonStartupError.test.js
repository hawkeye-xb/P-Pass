import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { startupFailureText } from "./daemonStartupError.js";

describe("startupFailureText", () => {
  it("keeps daemon stderr visible and explains a migration mismatch", () => {
    const stderr =
      "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";

    const text = startupFailureText(stderr);

    expect(text).toContain(stderr);
    expect(text).toContain("这个版本比你的照片库旧。请装回新版本。");
  });

  it("uses stderr-aware startup failures in both wizard variants", () => {
    for (const wizardPath of ["../Wizard.svelte", "../WizardWindows.svelte"]) {
      const wizard = readFileSync(new URL(wizardPath, import.meta.url), "utf8");
      expect(wizard).toContain('invoke("daemon_startup_error")');
      expect(wizard).not.toContain("后台服务没有在 10 秒内就绪");
    }
  });
});
