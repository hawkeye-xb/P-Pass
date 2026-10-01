// #557：设置页「语言：跟随系统 / 中文 / English」。
//
// 钉住三件事：
// 1. 选择会持久化（跟随系统 = 清掉存储，回到按系统语言）；
// 2. 启动时先用保存的选择，没有/垃圾值才用 navigator.language；
// 3. 切换时把解析后的语言报给托盘（set_tray_locale），然后重载窗口。
// 外加一条源码契约：设置页那一行确实调了 changeLanguage → applyLangPref。
//
// 反证（PR 里跑过）：删掉 applyLangPref 里的 setItem、删掉 current 初值里的
// readLangPref、删掉 invoke("set_tray_locale")——对应用例必须红。
import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";

function memoryStorage(init = {}) {
  const m = new Map(Object.entries(init));
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    _map: m,
  };
}

async function freshI18n({ saved, systemLang, storage } = {}) {
  vi.resetModules();
  const s = storage ?? memoryStorage(saved === undefined ? {} : { "ppass.ui_language": saved });
  vi.stubGlobal("localStorage", s);
  vi.stubGlobal("navigator", { language: systemLang });
  const mod = await import("./lib/i18n.js");
  return { mod, storage: s };
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("#557 启动时的语言", () => {
  it("有保存的选择就用它，不看系统语言", async () => {
    expect((await freshI18n({ saved: "en", systemLang: "zh-CN" })).mod.getLocale()).toBe("en");
    expect((await freshI18n({ saved: "zh", systemLang: "en-US" })).mod.getLocale()).toBe("zh");
  });

  it("没有选择、选了跟随系统或存的是垃圾值 → 按 navigator.language", async () => {
    expect((await freshI18n({ systemLang: "en-US" })).mod.getLocale()).toBe("en");
    expect((await freshI18n({ saved: "system", systemLang: "en-US" })).mod.getLocale()).toBe("en");
    expect((await freshI18n({ saved: "fr", systemLang: "zh-Hans" })).mod.getLocale()).toBe("zh");
  });

  it("存储读不了（隐私模式会抛）→ 按系统语言，不崩", async () => {
    const throwing = {
      getItem: () => {
        throw new Error("SecurityError");
      },
    };
    const { mod } = await freshI18n({ storage: throwing, systemLang: "en-GB" });
    expect(mod.getLocale()).toBe("en");
    expect(mod.readLangPref(throwing)).toBe("system");
  });
});

describe("#557 切换语言", () => {
  it("选 English：写入存储、托盘收到 en、窗口重载", async () => {
    const { mod, storage } = await freshI18n({ systemLang: "zh-CN" });
    const invoke = vi.fn().mockResolvedValue(null);
    const reload = vi.fn();
    await mod.applyLangPref("en", { storage, invoke, reload });

    expect(storage.getItem(mod.LANG_PREF_KEY)).toBe("en");
    expect(mod.readLangPref(storage)).toBe("en");
    expect(invoke).toHaveBeenCalledWith("set_tray_locale", { lang: "en" });
    expect(reload).toHaveBeenCalledTimes(1);
    // 托盘先改，再重载（重载后就没机会了）。
    expect(invoke.mock.invocationCallOrder[0]).toBeLessThan(reload.mock.invocationCallOrder[0]);
  });

  it("选跟随系统：清掉保存值，托盘收到按系统语言解析出的 zh/en", async () => {
    const { mod, storage } = await freshI18n({ saved: "zh", systemLang: "en-US" });
    const invoke = vi.fn().mockResolvedValue(null);
    await mod.applyLangPref("system", { storage, invoke, reload: vi.fn() });

    expect(storage.getItem(mod.LANG_PREF_KEY)).toBeNull();
    expect(invoke).toHaveBeenCalledWith("set_tray_locale", { lang: "en" });
  });

  it("托盘改字失败不挡切换（只影响托盘），窗口照样重载", async () => {
    const { mod, storage } = await freshI18n({ systemLang: "en-US" });
    const reload = vi.fn();
    await mod.applyLangPref("zh", {
      storage,
      invoke: vi.fn().mockRejectedValue(new Error("no tray")),
      reload,
    });
    expect(storage.getItem(mod.LANG_PREF_KEY)).toBe("zh");
    expect(reload).toHaveBeenCalledTimes(1);
  });

  it("存不进去就报错、不重载——否则重载后会悄悄回到旧语言", async () => {
    const { mod } = await freshI18n({ systemLang: "zh-CN" });
    const storage = {
      getItem: () => null,
      setItem: () => {
        throw new Error("QuotaExceededError");
      },
      removeItem: () => {},
    };
    const invoke = vi.fn();
    const reload = vi.fn();
    await expect(mod.applyLangPref("en", { storage, invoke, reload })).rejects.toThrow("QuotaExceededError");
    expect(invoke).not.toHaveBeenCalled();
    expect(reload).not.toHaveBeenCalled();
  });
});

describe("UI-19 设置页语言入口已隐藏（源码契约）", () => {
  const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(/\r\n/g, "\n");

  it("入口确实不在了：渲染标记与点击接线都不在源码里", () => {
    // 反证：把入口那段标记放回去，本条立刻复红。
    expect(app).not.toContain('data-testid="settings-language"');
    expect(app).not.toContain("onclick={() => changeLanguage(opt.pref)}");
  });

  it("能力未损坏：选项文案 key、语言偏好读取、applyLangPref 接线都还在", () => {
    for (const key of ["ui.language_system", "ui.language_zh", "ui.language_en"]) {
      expect(app).toContain(`"${key}"`);
    }
    expect(app).toContain("const langPref = readLangPref();");
    expect(app).toContain("await applyLangPref(pref, { invoke, reload: () => location.reload() });");
  });

  it("字典文案仍在（隐藏入口 ≠ 删文案）", () => {
    const zh = readFileSync(new URL("../../../assets/i18n/zh.json", import.meta.url), "utf8");
    expect(zh).toContain('"ui.language"');
    expect(zh).toContain('"ui.language_system"');
  });
});
