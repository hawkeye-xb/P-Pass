// DESK-36 (#456)：向导门的判定。
//
// 反证：把 serviceGate.js 里的 `&& !wizard.user_stopped` 去掉，
// 「用户停了服务再重开 App」那两条必须红。
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { shouldShowWizard, serviceCameBack } from "./serviceGate.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);

describe("DESK-36 向导门：用户主动停止 ≠ 向导中途退出", () => {
  it("从没配置过 → 完整向导（原语义不变）", () => {
    expect(shouldShowWizard({ configured: false, installed: false }, false)).toBe(true);
    // 残留的停止标记也不能让新机器跳过向导。
    expect(
      shouldShowWizard({ configured: false, installed: false, user_stopped: true }, false),
    ).toBe(true);
  });

  it("配过、服务没注册、不是用户停的 → 回向导（向导中途退出，xixi 实测反馈 3）", () => {
    expect(
      shouldShowWizard({ configured: true, installed: false, user_stopped: false }, false),
    ).toBe(true);
  });

  it("用户停了服务（autostart 被卸）→ 不回向导，留在主界面", () => {
    expect(
      shouldShowWizard({ configured: true, installed: false, user_stopped: true }, false),
    ).toBe(false);
  });

  it("服务在线或 wizard_state 还没查到 → 不显示向导", () => {
    expect(shouldShowWizard({ configured: false, installed: false }, true)).toBe(false);
    expect(shouldShowWizard(null, false)).toBe(false);
  });

  it("正常常驻、只是暂时离线 → 不显示向导（走自愈 / 启动按钮）", () => {
    expect(
      shouldShowWizard({ configured: true, installed: true, user_stopped: false }, false),
    ).toBe(false);
  });
});

describe("DESK-36 接线（App.svelte）", () => {
  const body = (re) => app.match(re)?.[0] ?? "";
  const refreshBody = body(/async function refresh\(\) \{[\s\S]*?\n  \}\n/);

  it("向导门用 shouldShowWizard，不再内联 configured/installed 的 ||", () => {
    expect(app).toContain("{#if shouldShowWizard(wizard, online)}");
    expect(app).not.toMatch(/!wizard\.configured \|\| !wizard\.installed/);
  });

  it("refresh 的自愈走 self_heal_daemon（Rust 现场判停止标记），不直接 resume", () => {
    expect(refreshBody).toContain('invoke("self_heal_daemon")');
    expect(refreshBody).not.toContain('invoke("resume_daemon_after_update")');
  });

  it("更新流程仍然调 resume_daemon_after_update（成功与失败两条路都在）", () => {
    const update = body(/async function checkForUpdate[\s\S]*?\n  \}\n/);
    expect(update.match(/invoke\("resume_daemon_after_update"\)/g)?.length).toBe(2);
  });

  it("停服后立即对账，托盘停止也订阅了", () => {
    const stopBody = body(/async function stopService\(\) \{[\s\S]*?\n  \}\n/);
    expect(stopBody).toContain("await syncServiceState();");
    expect(app).toContain('listen("service-stopped", onServiceStopped)');
    expect(app).toContain("unlistenStopped?.();");
  });
});

// DESK-38 (#475)：服务恢复的判定。反证：改成 `prev !== true && reachable`，
// 「正常启动」那条必须红。
describe("DESK-38 服务恢复判定", () => {
  it("见过离线 → 可达：算恢复（按钮启动 / 自愈 / 更新后恢复）", () => {
    expect(serviceCameBack(false, true)).toBe(true);
  });

  it("本进程第一次探活就可达：正常启动，不算恢复（墙不被清空重拉）", () => {
    expect(serviceCameBack(null, true)).toBe(false);
  });

  it("一直在线 / 仍然离线 / 刚掉线：都不算", () => {
    expect(serviceCameBack(true, true)).toBe(false);
    expect(serviceCameBack(false, false)).toBe(false);
    expect(serviceCameBack(true, false)).toBe(false);
  });

  it("接线：refresh 成功分支用它触发 onServiceBackOnline，失败分支记下离线", () => {
    const refreshBody = app.match(/async function refresh\(\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";
    expect(refreshBody).toContain("if (serviceCameBack(lastReachable, true)) onServiceBackOnline();");
    expect(refreshBody).toContain("lastReachable = false;");
  });
});
