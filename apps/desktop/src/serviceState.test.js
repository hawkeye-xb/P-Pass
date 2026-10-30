import { describe, it, expect } from "vitest";
import {
  SERVICE_STATES,
  isServiceState,
  serviceStateFromEvent,
  isServiceRunning,
  serviceRecoveryAction,
  canStopService,
  serviceStateLabelKey,
  serviceStateActionKey,
  serviceStateAfterDataRefresh,
} from "./serviceState.js";

describe("DESK-63 服务状态", () => {
  it("服务状态是 Rust 侧发出的五个值", () => {
    expect(SERVICE_STATES).toEqual([
      "not_configured",
      "stopped",
      "starting",
      "running",
      "unreachable",
    ]);
    for (const state of SERVICE_STATES) expect(isServiceState(state)).toBe(true);
    expect(isServiceState("online")).toBe(false);
    expect(isServiceState(undefined)).toBe(false);
    expect(isServiceState(null)).toBe(false);
  });

  it("只有 running 算运行中", () => {
    expect(isServiceRunning("running")).toBe(true);
    for (const state of ["not_configured", "stopped", "starting", "unreachable"]) {
      expect(isServiceRunning(state)).toBe(false);
    }
  });

  it("开始 / 停止按钮跟着状态走", () => {
    // 偏离 1：用户停的 → 启动；失联（可能卡死）→ 重启，先杀再拉。
    expect(serviceRecoveryAction("stopped")).toBe("start");
    expect(serviceRecoveryAction("unreachable")).toBe("restart");
    expect(serviceRecoveryAction("starting")).toBe(null);
    expect(serviceRecoveryAction("running")).toBe(null);
    expect(serviceRecoveryAction("not_configured")).toBe(null);

    // 停止只在服务真的在（或正在起）时出现，不会和「未运行」同屏。
    expect(canStopService("running")).toBe(true);
    expect(canStopService("starting")).toBe(true);
    expect(canStopService("stopped")).toBe(false);
    expect(canStopService("unreachable")).toBe(false);
    expect(canStopService("not_configured")).toBe(false);
  });

  it("文案 key 跟着状态（和停止原因）走", () => {
    expect(serviceStateLabelKey("running")).toBe("ui.service_running_long");
    expect(serviceStateLabelKey("starting")).toBe("ui.starting");
    expect(serviceStateLabelKey("stopped")).toBe("ui.offline_banner");
    expect(serviceStateLabelKey("unreachable")).toBe("ui.offline_banner");
    expect(serviceStateActionKey("stopped")).toBe("ui.service_stopped");
    expect(serviceStateActionKey("unreachable")).toBe("ui.offline_action");
    // F7：外面正常停掉的单独一句（不是「开机也不起」）；本 App 里停的照旧。
    expect(serviceStateActionKey("stopped", "stopped outside")).toBe("ui.service_stopped_outside");
    expect(serviceStateActionKey("stopped", "user stopped")).toBe("ui.service_stopped");
    expect(serviceStateActionKey("unreachable", "stopped outside")).toBe("ui.offline_action");
  });

  it("事件载荷只接受已知状态", () => {
    expect(serviceStateFromEvent({ state: "unreachable" })).toBe("unreachable");
    expect(serviceStateFromEvent({ state: "stopped" })).toBe("stopped");
    expect(serviceStateFromEvent({ state: "bogus" })).toBe(null);
    expect(serviceStateFromEvent(null)).toBe(null);
    expect(serviceStateFromEvent(undefined)).toBe(null);
  });

  it("status 成功 + devices 失败仍是 running：数据刷新不改服务状态", () => {
    // 这条是 #946 的核心契约：数据层失败只进数据区，不能把 running 翻成
    // unreachable。真正的状态迁移只来自 Rust 的 service-state 事件。
    expect(serviceStateAfterDataRefresh("running")).toBe("running");
  });
});
