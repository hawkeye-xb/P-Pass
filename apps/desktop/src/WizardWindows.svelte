<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { Button } from "$lib/components/ui/button";
  import { startupFailureText } from "$lib/daemonStartupError.js";
  import { t, errText } from "$lib/i18n.js";

  // Windows onboarding — separate component, not a branch inside the
  // macOS Wizard.svelte (2026-08-26, W1 real-box run: 用户明确要求整块
  // 按环境拆分，而不是在同一份文案里堆 if windows/else). Copy differs
  // wherever the OS differs (Finder vs 文件资源管理器, TCC-protected
  // 桌面/文稿 vs Windows 没有等价保护目录, macOS Gatekeeper 右键打开 vs
  // Windows SmartScreen "更多信息→仍要运行"). Structure/steps/state
  // machine mirror Wizard.svelte on purpose so the two stay easy to
  // diff when a shared behavior (e.g. finishSetup's readiness poll)
  // changes on one side and needs porting to the other.
  // DESK-15：按钮视觉合同收进 Button 组件本身，见 Wizard.svelte 同条注释。
  const WIZARD_PRIMARY_WIDE = "px-[26px]";

  let { defaultDir, configuredLibraryDir, onDone } = $props();

  let step = $state(1);
  let libraryDir = $state(configuredLibraryDir || defaultDir);
  let power = $state(null); // {kind, minutes}
  let busy = $state(false);
  let error = $state("");

  async function chooseFolder() {
    const dir = await openDialog({
      directory: true,
      title: t("ui.wizard_choose_folder_title"),
      defaultPath: defaultDir,
    });
    if (dir) libraryDir = dir;
  }

  function useDefault() {
    libraryDir = defaultDir;
  }

  let sleepFixBusy = $state(false);
  let sleepFixError = $state("");
  async function fixAutoSleep() {
    sleepFixBusy = true;
    sleepFixError = "";
    try {
      await invoke("disable_auto_sleep");
      power = await invoke("power_hint");
    } catch (e) {
      sleepFixError = errText(e);
    } finally {
      sleepFixBusy = false;
    }
  }

  async function toStep2() {
    error = "";
    busy = true;
    try {
      await invoke("write_config", { libraryDir });
      power = await invoke("power_hint");
      step = 2;
    } catch (e) {
      error = t("ui.wizard_save_failed", { err: errText(e) });
    } finally {
      busy = false;
    }
  }

  async function toStep3() {
    step = 3;
  }

  // W1 (2026-08-26): install_autostart() on Windows now spawns the
  // daemon immediately (crates/platform/src/windows.rs) instead of only
  // writing the Run key for next login — that gap used to make this
  // poll always time out and report a generic "没有在 10 秒内就绪",
  // masking the real platform bug. Same poll shape kept here since the
  // fix lives in the backend, not in this wait loop.
  async function finishSetup() {
    error = "";
    busy = true;
    try {
      await invoke("start_daemon");
      let ready = false;
      for (let i = 0; i < 20; i++) {
        await new Promise((r) => setTimeout(r, 500));
        try {
          await invoke("daemon_call", { method: "status", params: {} });
          ready = true;
          break;
        } catch (_) {}
      }
      if (!ready) {
        let stderr = null;
        try {
          stderr = await invoke("daemon_startup_error");
        } catch (_) {}
        throw new Error(
          startupFailureText(stderr) || t("ui.wizard_daemon_not_started"),
        );
      }
      onDone();
    } catch (e) {
      error = t("ui.wizard_start_failed", { err: errText(e) });
    } finally {
      busy = false;
    }
  }
</script>

<div class="mt-4 flex flex-col gap-[22px] rounded-xl border border-border bg-paper px-8 py-7">
  <div class="flex gap-2">
    {#each [t("ui.wizard_step_library"), t("ui.wizard_step_sleep"), t("ui.wizard_step_service")] as label, i}
      <span class="text-[13px] font-semibold {step === i + 1 ? 'text-ink' : step > i + 1 ? 'text-safe' : 'text-ink-40'}">
        {i + 1}. {label}
      </span>
    {/each}
  </div>

  {#if error}
    <p class="m-0 rounded-md bg-act-bg px-[14px] py-[10px] text-[15px] text-act">{error}</p>
  {/if}

  {#if step === 1}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_library_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_library_body_win")}</p>
      <div class="flex items-center gap-[10px]">
        <code class="flex-1 rounded-xl bg-linen px-4 py-[13px] font-mono text-[14px] text-ink-60 break-all">{libraryDir}</code>
        <Button variant="secondary" class="flex-none" onclick={chooseFolder}>{t("ui.wizard_change_folder")}</Button>
      </div>
      {#if libraryDir !== defaultDir}
        <Button variant="link" tone="safe" class="self-start" onclick={useDefault} title={t("ui.wizard_use_default")}>↺ {t("ui.wizard_use_default")}</Button>
      {/if}
      <!-- Windows 没有 macOS TCC 那样的系统级保护目录弹窗；真正的坑是系统盘
           受保护路径（Program Files 等）权限受限、云盘同步目录（OneDrive
           等）可能带来重复占用/同步冲突。默认路径落在用户的「图片」目录，
           不需要额外提醒，只在选到明显有风险的地方才提示。 -->
      <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[13.5px] leading-[1.6] text-ink-60">{t("ui.wizard_library_tip_win")}</p>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <span></span>
      <Button class={WIZARD_PRIMARY_WIDE} disabled={!libraryDir || busy} onclick={toStep2}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if step === 2}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_sleep_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_sleep_body")}</p>
      {#if power?.kind === "never"}
        <div class="flex items-center gap-3 rounded-xl border border-border px-[18px] py-[14px]">
          <span class="h-[9px] w-[9px] flex-none rounded-full bg-safe"></span>
          <span class="flex-1 text-[15px] font-semibold">{t("ui.wizard_sleep_never")}</span>
          <span class="text-[13px] text-safe">✓ {t("ui.wizard_check_passed")}</span>
        </div>
      {:else if power?.kind === "sleeps"}
        <div class="flex flex-col gap-3 rounded-xl border border-border bg-waiting-bg px-[18px] py-[14px]">
          <div class="flex items-center gap-3">
            <span class="h-[9px] w-[9px] flex-none rounded-full bg-waiting"></span>
            <div class="flex-1">
              <p class="m-0 text-[15px] font-semibold">{t("ui.wizard_sleep_on")}</p>
              <p class="m-0 mt-[3px] text-[13px] leading-[1.5] text-ink-60">
                {t("ui.wizard_sleep_minutes", { n: power.minutes })}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-[10px]">
            <Button size="compact" disabled={sleepFixBusy} onclick={fixAutoSleep}>
              {sleepFixBusy ? t("ui.wizard_sleep_fixing") : t("ui.wizard_sleep_fix")}
            </Button>
            <Button variant="secondary" size="compact" onclick={() => invoke("open_power_settings")}>{t("ui.wizard_open_power_settings")}</Button>
          </div>
          {#if sleepFixError}
            <p class="m-0 text-[13px] text-act">{t("ui.wizard_sleep_fix_failed_win", { err: sleepFixError })}</p>
          {/if}
        </div>
      {:else}
        <p class="m-0 text-[13px] leading-[1.6] text-ink-40">{t("ui.wizard_power_unknown")}</p>
      {/if}
    </div>
    <div class="mt-auto flex items-center justify-between">
      <Button variant="link" onclick={() => (step = 1)}>‹ {t("ui.wizard_back")}</Button>
      <Button class={WIZARD_PRIMARY_WIDE} onclick={toStep3}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if step === 3}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_service_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_service_body")}</p>
      <div class="rounded-xl border border-border">
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_asks_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_asks_win")}</span>
        </div>
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_wont_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_wont")}</span>
        </div>
        <div class="flex gap-3 px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_blocked_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_blocked_win")}</span>
        </div>
      </div>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <Button variant="link" onclick={() => (step = 2)}>‹ {t("ui.wizard_back")}</Button>
      <Button class={WIZARD_PRIMARY_WIDE} disabled={busy} onclick={finishSetup}>
        {busy ? t("ui.starting") : t("ui.wizard_finish")}
      </Button>
    </div>
  {/if}
</div>
