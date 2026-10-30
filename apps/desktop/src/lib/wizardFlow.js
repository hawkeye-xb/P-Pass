// #1045：两份首启向导视图（Wizard.svelte / WizardWindows.svelte）共用的状态机。
//
// 以前两份视图逐字照抄了 `finishSetup`、`chooseFolder`、步骤条与错误条，每次
// 改一边都要手动移植另一边（WizardWindows 顶部注释自己就写着「mirror on
// purpose so the two stay easy to diff」）。2026-08-26 拍板两份视图本身保留
// （文案按系统拆开），但**行为只有一份**，在这里：
//
//   第 1 步 选库 ─ toStep2() ─▶ 第 2 步 睡眠 ─ toStep3() ─▶ 第 3 步 常驻服务 ─ finishSetup() ─▶ onDone()
//
// 前两步只收集选择，磁盘上什么都不写；第 3 步「完成」才一次性生效：写库位置
// （`write_config` → daemon `config.set_library`）→ 启动常驻服务。这样中途改目录、
// 中途退出都不留半套配置或空库目录，本地网络授权也只在第 3 步出现（统一回归首启
// 实测：第 1 步就写库位置会一次性拉起 daemon，留下空的默认库、授权弹窗提前）。
//
// 两个视图只保留各自的文案，以及第 2 步的渲染（macOS 要用户处理睡眠、Windows
// 由 daemon 保持唤醒只需说明）。第 2 步在逻辑上的差别只有一处：macOS 进第 2 步
// 前要问一次电源状态——经 `beforeStep2` 钩子注入，状态机本身不认识平台。
//
// 为什么是工厂 + `onChange` 回调、不是 `.svelte.js` 里的 rune：状态机要能脱离
// Svelte 单测；视图把 `onChange(patch)` 的结果并进自己的 `$state` 即可。
//
// 「向导要不要出现」不在这里——那是 Rust `wizard_state.show_wizard` 的事。

import { invoke } from "@tauri-apps/api/core";

import { callDaemon } from "./daemonApi.js";
import { startupFailureKey } from "./daemonStartupError.js";
import { errMessage, t } from "./i18n.js";

/** 向导共三步。 */
export const WIZARD_STEP_COUNT = 3;

/** 就绪轮询：20 次 × 500ms = 10 秒（daemon 拉起来到能答 status 的上限）。 */
export const READY_POLLS = 20;
export const READY_POLL_MS = 500;

/**
 * 步骤条：每一步的编号、文案与状态（current / done / todo）。视图只管把它渲染
 * 成各自的 class。
 * @param {number} step 当前步骤（1 起）
 */
export function stepBar(step) {
  const labels = [
    t("ui.wizard_step_library"),
    t("ui.wizard_step_sleep"),
    t("ui.wizard_step_service"),
  ];
  return labels.map((label, i) => ({
    n: i + 1,
    label,
    state: step === i + 1 ? "current" : step > i + 1 ? "done" : "todo",
  }));
}

/**
 * @param {object} opts
 * @param {string} opts.defaultDir              新建库的默认目录
 * @param {string | null} [opts.configuredLibraryDir]  config 已指向的库（预填，防孤儿库，T-042b）
 * @param {() => void} opts.onDone              第 3 步完成、服务就绪
 * @param {(patch: object) => void} opts.onChange  状态变化时给出变化的字段
 *        （`step` / `libraryDir` / `busy` / `error`）
 * @param {() => Promise<void>} [opts.beforeStep2]
 *        进第 2 步之前的钩子（macOS：读电源状态）。抛错 = 留在第 1 步并显示红条。
 */
export function createWizardFlow({
  defaultDir,
  configuredLibraryDir,
  onDone,
  onChange,
  beforeStep2,
}) {
  // DESK-05：新装时默认填 defaultDir——不再要求先点「用默认位置」；
  // T-042b：config 已指向某库（oneshot 降级 / 中途退出回向导）就预填它。
  const state = {
    step: 1,
    libraryDir: configuredLibraryDir || defaultDir,
    busy: false,
    error: "",
  };

  function set(patch) {
    Object.assign(state, patch);
    onChange(patch);
  }

  async function chooseFolder() {
    // #1150：系统对话框由壳弹，选定的目录留在壳里；这里只拿到展示用的字符串。
    const dir = await invoke("pick_library_dir", {
      title: t("ui.wizard_choose_folder_title"),
      fromDefault: true,
    });
    if (dir) set({ libraryDir: dir });
  }

  async function useDefault() {
    await invoke("use_default_library_dir");
    set({ libraryDir: defaultDir });
  }

  /** 第 1 → 2 步：只记住选择（目录在第 3 步「完成」时才写）。 */
  async function toStep2() {
    set({ error: "", busy: true });
    try {
      if (beforeStep2) await beforeStep2();
      set({ step: 2 });
    } catch (e) {
      set({ error: errMessage(e, "ui.wizard_save_failed") });
    } finally {
      set({ busy: false });
    }
  }

  /**
   * 第 2 → 3 步。第 3 步是「设为常驻服务」说明页——先讲清楚会弹什么、不会做什么、
   * 被拦怎么办，再动手；真正的 start_daemon（含 autostart 注册）在 finishSetup。
   */
  function toStep3() {
    set({ step: 3 });
  }

  function back() {
    set({ step: Math.max(1, state.step - 1) });
  }

  /**
   * 第 3 步完成 = 整个 onboarding 完成（不再单开扫码页，总览页常驻「添加设备」）。
   * 启动 daemon（此刻才注册开机自启）→ 轮询 status 确认真的就绪（不然主界面会闪
   * 一下「服务未连接」）→ onDone()。起不来时红条说 daemon 认出的原因（DESK-09 的人话），
   * 认不出就用兜底文案；B13 起 stderr 原文只进 console，不进红条。
   */
  async function finishSetup() {
    set({ error: "", busy: true });
    // 先写库位置：daemon 校验（存在 / 可写 / 不嵌套）不过就回第 1 步重选，常驻服务不启动。
    try {
      await invoke("write_config");
    } catch (e) {
      set({ step: 1, busy: false, error: errMessage(e, "ui.wizard_save_failed") });
      return;
    }
    try {
      await invoke("start_daemon");
      let ready = false;
      for (let i = 0; i < READY_POLLS; i++) {
        await new Promise((r) => setTimeout(r, READY_POLL_MS));
        try {
          await callDaemon("status");
          ready = true;
          break;
        } catch (_) {}
      }
      if (!ready) {
        let stderr = null;
        try {
          stderr = await invoke("daemon_startup_error");
        } catch (_) {}
        // B13：daemon 认出原因就说那一句，否则说兜底；stderr 原文只进 console。
        throw startupFailureKey(stderr) || "ui.wizard_daemon_not_started";
      }
      onDone();
    } catch (e) {
      set({ error: errMessage(e, "ui.wizard_start_failed") });
    } finally {
      set({ busy: false });
    }
  }

  return {
    /** 当前状态的快照（初值用；之后以 onChange 的 patch 为准）。 */
    snapshot: () => ({ ...state }),
    chooseFolder,
    useDefault,
    toStep2,
    toStep3,
    back,
    finishSetup,
  };
}
