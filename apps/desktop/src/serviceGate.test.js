// DESK-36 (#456) 向导门的判据矩阵在 Rust（`show_wizard`，lib.rs 的
// `the_wizard_gate_separates_user_stop_from_an_abandoned_wizard`，#1045）；
// 这里只钉前端接线：向导门读 Rust 给的 `wizard.show_wizard`，不再自己拼。
import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { serviceCameBack } from "./serviceGate.js";

const app = readFileSync(new URL("./App.svelte", import.meta.url), "utf8").replace(
  /\r\n/g,
  "\n",
);

describe("DESK-36 接线（App.svelte）", () => {
  const body = (re) => app.match(re)?.[0] ?? "";
  const refreshBody = body(/async function refresh\(\) \{[\s\S]*?\n  \}\n/);
  const selfHealBody = body(/async function maybeSelfHeal\(\) \{[\s\S]*?\n  \}\n/);

  it("向导门读 Rust 的 show_wizard，前端不再拿 configured/installed/user_stopped 自己拼", () => {
    expect(app).toContain("{#if wizard?.show_wizard}");
    expect(app).not.toMatch(/shouldShowWizard/);
    // 配置、安装、停止三个原料字段都不许在前端被读（`configured_library_dir` 是预填值，不算）。
    for (const ingredient of [/wizard\??\.configured\b(?!_)/, /wizard\??\.installed\b/, /wizard\??\.user_stopped\b/]) {
      expect(app, String(ingredient)).not.toMatch(ingredient);
    }
  });

  it("服务状态每次变化都重读 wizard_state（show_wizard 依赖 Rust 持有的在线状态）", () => {
    const applyBody =
      app.match(/function applyServiceState\(next\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";
    expect(applyBody).toContain("checkWizard()");
  });

  it("自愈只做冷却节流，要不要自愈由 Rust 的 self_heal_allowed 现场判", () => {
    expect(selfHealBody).not.toContain("wizard");
    expect(selfHealBody).toContain("SELF_HEAL_COOLDOWN_MS");
  });

  it("自愈走 maybeSelfHeal（Rust 现场判停止标记）， refresh 不再触发自愈", () => {
    expect(refreshBody).not.toContain('invoke("self_heal_daemon")');
    expect(selfHealBody).toContain('invoke("self_heal_daemon")');
    expect(selfHealBody).not.toContain('invoke("resume_daemon_after_update")');
  });

  it("更新装完不再由旧壳拉 daemon（新壳启动对账），装失败走自愈（#1046）", () => {
    const update = body(/async function checkForUpdate[\s\S]*?\n  \}\n/);
    expect(update).not.toContain("resume_daemon_after_update");
    // #1060：失败自愈在 runUpdate（updateFlow.js，有单测）里，App 只把 self_heal_daemon
    // 接进去；成功路径（catch 之前）不碰。
    const success = update.slice(0, update.lastIndexOf("} catch (e) {"));
    expect(success).toContain('selfHeal: () => invoke("self_heal_daemon")');
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

  it("接线：service-state 到 running 时触发 onServiceBackOnline，数据刷新不再判恢复", () => {
    const applyBody =
      app.match(/function applyServiceState\(next\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";
    const refreshBody = app.match(/async function refresh\(\) \{[\s\S]*?\n  \}\n/)?.[0] ?? "";
    expect(applyBody).toContain("onServiceBackOnline()");
    expect(refreshBody).not.toContain("onServiceBackOnline");
    expect(refreshBody).not.toContain("lastReachable");
  });
});
