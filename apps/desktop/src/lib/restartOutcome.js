// 「重启后台服务」的结果怎么说（纯函数，restartOutcome.test.js）。
//
// Rust `restart_outcome` 只给事实：答没答上（still_starting）、杀前 / 杀后版本、版本变没变（changed）。
// 「版本没变」只在更新场景算没成功（磁盘上的服务文件没换，DAE-04）；失联恢复场景（报错 toast、
// 首页阻断卡上的按钮）要的是服务回来，答上了就是恢复了（v0.10.3-test.1 回归 F3）。

/**
 * @param {{changed?: boolean, still_starting?: boolean, old_version?: string|null, new_version?: string|null}} r
 * @param {"update" | "recover"} purpose
 * @returns {{ key: string, params?: object, tone: "success" | "warning" }}
 */
export function restartOutcomeMessage(r, purpose) {
  if (r?.still_starting) return { key: "ui.restart_service_still_starting", tone: "warning" };
  if (purpose === "recover") return { key: "ui.restart_service_recovered", tone: "success" };
  if (r?.changed) {
    return r.old_version
      ? { key: "ui.restart_service_ok", params: { from: r.old_version, to: r.new_version }, tone: "success" }
      : { key: "ui.restart_service_started", params: { version: r.new_version }, tone: "success" };
  }
  return { key: "ui.restart_service_no_change", params: { version: r?.new_version ?? "?" }, tone: "warning" };
}
