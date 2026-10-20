// #1060：应用内更新的执行顺序——下载 → （仅需要的平台）停 daemon → 安装。
//
// 以前点「下载并安装」就先停 daemon 再 downloadAndInstall()：下载那几分钟备份被
// 打断；macOS 上 launchd KeepAlive 3 秒就把旧内核拉回来，装完新壳启动再换一次，
// 一次更新重启两次。真正需要停的只有「替换文件」那一刻。所以（两平台一致）：
// - 下载阶段绝不停；
// - 下载完成后、install() 之前暂停一次（壳侧：服务管理器卸下、登记保留、不写
//   用户停止标记；用户本来就停过的壳侧不动）；
// - 暂停到安装结束是「为更新暂停」窗口：断连不触发自愈（Rust 侧 UpdatePause），
//   否则旧二进制在替换前被拉回、一次更新停两次；
// - 失败（下载或安装）先关窗口再自愈（用户主动停过的不拉，判据在 Rust 侧）。
// 装完不在这里拉回 daemon：新壳启动时的「更新后恢复」负责（#1060 / #1046）。
// 依赖注入，便于不起 Tauri 直接测。

/**
 * @param {object} deps
 * @param {{download: Function, install: Function}} deps.update  tauri-plugin-updater 的 Update
 * @param {() => Promise<unknown>} deps.pauseDaemon   尽力而为：失败只记日志，不挡更新
 * @param {() => Promise<unknown>} deps.selfHeal      失败路径用，尽力而为
 * @param {(phase: "downloading" | "installing") => void} deps.onPhase
 * @param {(percent: number | null) => void} deps.onProgress  总长未知时给 null，不编百分比
 * @param {(msg: string, e: unknown) => void} [deps.warn]
 */
export async function runUpdate({
  update,
  pauseDaemon,
  selfHeal,
  onPhase,
  onProgress,
  warn = () => {},
}) {
  try {
    onPhase("downloading");
    let total = 0;
    let done = 0;
    await update.download((ev) => {
      if (ev.event === "Started") {
        total = ev.data?.contentLength || 0;
        done = 0;
        onProgress(total ? 0 : null);
      } else if (ev.event === "Progress") {
        done += ev.data?.chunkLength || 0;
        onProgress(
          total ? Math.min(100, Math.round((done / total) * 100)) : null,
        );
      } else if (ev.event === "Finished") {
        onPhase("installing");
        onProgress(100);
      }
    });
    try {
      await pauseDaemon();
    } catch (e) {
      warn("pause_daemon_for_update failed (continuing anyway):", e);
    }
    await update.install();
  } catch (e) {
    try {
      await selfHeal();
    } catch (_) {}
    throw e;
  }
}
