// DESK-34 (#428): 照片墙缩略图单元的加载编排（PhotoThumb.svelte 的逻辑本体）。
//
// daemon 生成失败/超预算时回的是内置占位图，响应里带 `placeholder: true`
// 和 `retry_after_ms`（负缓存剩余窗口，或生成仍在跑时的一个预算）。之前前端
// 把占位图当成功结果存下，组件活着就一直灰——daemon 那边窗口早过了也不重拉。
//
// 规则（有界，不轮询）：
// - 真图：终态，永不重拉。
// - 占位图且 retry_after_ms > 0：等窗口到期，**且组件可见**时重取一次；
//   每次挂载至多一次，重取回来仍是占位图就停在占位图。
// - 占位图且 retry_after_ms == 0（未知资产/坏 hash）：不重取。
// - 调用报错：显示失败灰块（原行为），不自己重取。
// - #551：调用报错后，只有「服务恢复」信号（retryFailed()，App 在
//   onServiceBackOnline 时发）才重取——等组件可见时拉一次。停服期间进墙的
//   格子全失败，而 DESK-38 规定恢复时墙不重建 DOM，没有这个入口灰块就永久
//   留在同一次挂载里。真图/占位图/加载中调它一律 no-op，重复调用幂等。
//
// 依赖全部注入，便于测试：
//   call(method, params) -> Promise<ThumbData>
//   schedule(ms, fn)     -> cancel()
//   whenVisible(fn)      -> cancel()   组件（已/将）可见时调 fn 一次
//   onSrc(src) / onFailed()
// params 在每次 load 时读（组件传 getter，拿到的是当前 props）。

export function createThumbLoader(deps, params) {
  const { call, schedule, whenVisible, onSrc, onFailed } = deps;
  let retried = false;
  let disposed = false;
  let cancelPending = null;
  // #551：上一次 load 以调用报错告终（且之后没有新的 load 在跑）。
  let lastFailed = false;
  let cancelFailedRetry = null;

  async function load() {
    lastFailed = false;
    let r;
    try {
      r = await call("thumb.get", { hash: params.hash, size: params.size });
    } catch (_) {
      if (!disposed) {
        lastFailed = true;
        onFailed();
      }
      return;
    }
    if (disposed) return;
    onSrc(`data:image/jpeg;base64,${r.jpeg_base64}`);
    const wait = Number(r.retry_after_ms) || 0;
    if (r.placeholder && wait > 0 && !retried) {
      retried = true;
      cancelPending = schedule(wait, () => {
        cancelPending = whenVisible(() => {
          cancelPending = null;
          if (!disposed) load();
        });
      });
    }
  }

  function retryFailed() {
    if (disposed || !lastFailed) return;
    if (cancelFailedRetry) cancelFailedRetry();
    cancelFailedRetry = whenVisible(() => {
      cancelFailedRetry = null;
      if (!disposed && lastFailed) load();
    });
  }

  return {
    load,
    retryFailed,
    dispose() {
      disposed = true;
      if (cancelPending) cancelPending();
      cancelPending = null;
      if (cancelFailedRetry) cancelFailedRetry();
      cancelFailedRetry = null;
    },
  };
}
