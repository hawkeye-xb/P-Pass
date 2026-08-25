import { describe, it, expect } from "vitest";
import { startupFailureMessage, daemonErrorHint } from "./daemonStartup.js";

const MIGRATION =
  "Error: migration: migration 2 was previously applied but is missing in the resolved migrations";

describe("DESK-09 向导必须透出 daemon 的真实错误", () => {
  it("界面文本包含 daemon 输出的那一行原文", () => {
    const msg = startupFailureMessage({
      captured: true,
      line: MIGRATION,
      errPath: "/Users/x/Library/Logs/p-pass-daemon.err",
    });
    // 原文可搜索、可贴给开发者——不翻译、不截断。
    expect(msg).toContain(
      "migration 2 was previously applied but is missing in the resolved migrations",
    );
    expect(msg).toContain("/Users/x/Library/Logs/p-pass-daemon.err");
  });

  it("迁移不兼容那类错误给出「装回新版本」这句人话", () => {
    const msg = startupFailureMessage({ captured: true, line: MIGRATION });
    expect(msg).toContain("装回新版本");
    // 人话在原文之前——先看懂，再看细节。
    expect(msg.indexOf("装回新版本")).toBeLessThan(msg.indexOf("migration 2"));
  });

  it("超时不被当成原因", () => {
    const msg = startupFailureMessage({ captured: true, line: MIGRATION });
    expect(msg).toContain("超时只是我们等不下去了，不是失败的原因");
    // 「没有在 10 秒内就绪」这种把超时当结论的说法不许再出现。
    expect(msg).not.toContain("没有在 10 秒内就绪");
  });

  it("库目录不可写 → 让人换个有写权限的文件夹", () => {
    const line = "Error: opening index: Read-only file system (os error 30)";
    expect(daemonErrorHint(line)).toContain("写权限");
    expect(startupFailureMessage({ captured: true, line })).toContain(line);
  });

  it("端口被占用 → 不覆盖 daemon 已有的人话错误，只原样透出", () => {
    const line = "Error: 端口 41145 已被其它程序占用（换个端口或先停掉它）";
    expect(daemonErrorHint(line)).toBeNull();
    expect(startupFailureMessage({ captured: true, line })).toContain(line);
  });

  it("没捕获到新输出时明说没捕获到，并指向导出日志", () => {
    const msg = startupFailureMessage({ captured: false, line: null });
    expect(msg).toContain("没有捕获到后台服务的新错误输出");
    expect(msg).toContain("导出日志");
  });

  it("不认识的错误也照登原文（不拿猜测盖住真错误）", () => {
    const line = "Error: something nobody classified yet";
    expect(daemonErrorHint(line)).toBeNull();
    expect(startupFailureMessage({ captured: true, line })).toContain(line);
  });
});
