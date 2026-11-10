// #1402 卡1：总览顶部、备份状态卡、设备页三处读同一组计数，用同一份文案。
// 判据「paired 不数已断开的」在 daemon（crates/daemon/tests/ipc_flow.rs：
// `device_rows_carry_daemon_conclusions_and_status_counts_match_the_list`）；
// 这里钉住的是这三处怎么把两个数说给用户听。
// 反证：disconnectedClause 恒返回空串、noDevicesText 不看 disconnected，第二、四条变红。
import { test, expect } from "vitest";
import { disconnectedClause, noDevicesText } from "./lib/deviceCounts.js";
import { setLocale } from "./lib/i18n.js";

setLocale("zh");

test("有已断开的设备就补一句「另有 M 台已断开」", () => {
  expect(disconnectedClause(1)).toBe("（另有 1 台已断开）");
  expect(disconnectedClause(3)).toBe("（另有 3 台已断开）");
});

test("没有已断开的就不添这句", () => {
  expect(disconnectedClause(0)).toBe("");
});

test("0 台在用、也没有已断开时，空状态只说不配对", () => {
  expect(noDevicesText(0)).toBe("还没有配对的设备。");
});

test("0 台在用但有已断开时，空状态说清是几台已断开", () => {
  expect(noDevicesText(1)).toBe("还没有配对的设备（1 台已断开）。");
  expect(noDevicesText(2)).toBe("还没有配对的设备（2 台已断开）。");
});
