// #1253：照片库找不到时窗口这一侧的两件事——强提示只在状态变化时发一次，「重新检查」如实回答。

/**
 * 进入 / 离开「找不到照片库」时各通知壳一次（窗口置前、程序坞跳动、菜单栏「!」；恢复后撤掉）。
 * 每次 refresh 都会调用 `sync`，只有状态真的变了才发——不能每 3 秒把窗口拽到前台一次。
 */
export function createLibraryAlert(invoke, getLocale) {
  let active = false;
  return {
    sync(missing) {
      const next = Boolean(missing);
      if (next === active) return;
      active = next;
      Promise.resolve(invoke("set_library_alert", { active: next, lang: getLocale() })).catch(() => {});
    },
  };
}

/**
 * 「重新检查」：后台说库回来了（`found: true`）⇒ 它应答后自己带着库重启，窗口等下一次 refresh；
 * 还不在 ⇒ 如实告诉用户。返回 `"restarting"` / `"still_missing"`。
 */
export async function recheckLibrary(callDaemon) {
  const reply = await callDaemon("library.recheck", {});
  return reply?.found === true ? "restarting" : "still_missing";
}
