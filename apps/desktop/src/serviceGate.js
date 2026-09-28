// DESK-36 (#456)：首启向导什么时候接管整个窗口。
//
// 抽成纯函数是因为这条判定一改就牵动两件事：
//   1. 用户点「停止服务」会卸掉 autostart（lib.rs stop_daemon），`installed`
//      随之变 false。原来的门 `(!configured || !installed) && !online` 把这个
//      状态和「向导走到一半退出」当成同一回事——重开 App 就被打回完整
//      onboard（#155 的停服路径），而本卡要在停服后立刻刷新 wizard_state，
//      不改门的话连当前会话都会当场掉进向导。
//   2. `user_stopped` 来自 Rust 侧的持久标记（wizard_state），前端和托盘
//      停止共用同一份；这里只读，不自己记。

/**
 * @param {{configured?: boolean, installed?: boolean, user_stopped?: boolean} | null} wizard
 *   `wizard_state` 的返回；null = 还没查到
 * @param {boolean} online  daemon 是否可达
 * @returns {boolean} 要不要显示首启向导
 */
export function shouldShowWizard(wizard, online) {
  if (!wizard || online) return false;
  // 从没配置过：完整向导（原语义，不动）。
  if (!wizard.configured) return true;
  // 配过、服务没注册：向导中途退出才回向导（xixi 实测反馈 3）；
  // 用户自己停的就留在主界面，给「启动服务」按钮。
  return !wizard.installed && !wizard.user_stopped;
}

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
