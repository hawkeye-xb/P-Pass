// 首启向导什么时候接管整个窗口：判据只在 Rust（`wizard_state.show_wizard`，
// `apps/desktop/src-tauri/src/lib.rs` 的 `show_wizard`，#1045）。以前这里有一份
// `shouldShowWizard`，与 Rust 的 `self_heal_allowed` 各写一遍 configured /
// installed / user_stopped 的组合，已删除——前端只读 Rust 的结论。

// DESK-38 (#475)：「服务刚恢复」的判定——照片墙这类只在首拉时读一次 daemon
// 的视图，要靠它知道该重拉了。
//
// 只认「确实见过离线 → 现在可达」：`prev === null`（本进程还没探过）到可达
// 是正常启动，不算恢复——那时各视图的首拉本来就会成功，再清一遍只会让墙
// 重复请求、闪一下。
/**
 * @param {boolean | null} prev  上一次探活结果；null = 本进程还没探过
 * @param {boolean} reachable     这一次探活是否可达
 * @returns {boolean} 是否应当把依赖服务的视图重新拉一遍
 */
export function serviceCameBack(prev, reachable) {
  return prev === false && reachable === true;
}
