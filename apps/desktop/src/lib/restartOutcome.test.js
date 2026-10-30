import { describe, expect, it } from "vitest";
import { restartOutcomeMessage } from "./restartOutcome.js";

describe("F3：重启结果按场景说", () => {
  const same = { changed: false, still_starting: false, old_version: "0.10.3", new_version: "0.10.3" };

  it("失联恢复：答上了就是恢复了，版本没变不算失败", () => {
    expect(restartOutcomeMessage(same, "recover")).toEqual({ key: "ui.restart_service_recovered", tone: "success" });
    expect(restartOutcomeMessage({ changed: true, still_starting: false, old_version: null, new_version: "0.10.3" }, "recover").key).toBe(
      "ui.restart_service_recovered",
    );
  });

  it("更新场景：版本没变 = 服务文件没换（DAE-04 判据不动）", () => {
    expect(restartOutcomeMessage(same, "update")).toEqual({
      key: "ui.restart_service_no_change",
      params: { version: "0.10.3" },
      tone: "warning",
    });
    expect(restartOutcomeMessage({ changed: true, old_version: "0.10.2", new_version: "0.10.3" }, "update")).toEqual({
      key: "ui.restart_service_ok",
      params: { from: "0.10.2", to: "0.10.3" },
      tone: "success",
    });
    expect(restartOutcomeMessage({ changed: true, old_version: null, new_version: "0.10.3" }, "update").key).toBe("ui.restart_service_started");
  });

  it("还没答上：两种场景都只说正在启动，不说失败（DESK-44）", () => {
    for (const purpose of ["update", "recover"]) {
      expect(restartOutcomeMessage({ still_starting: true }, purpose).key).toBe("ui.restart_service_still_starting");
    }
  });
});
