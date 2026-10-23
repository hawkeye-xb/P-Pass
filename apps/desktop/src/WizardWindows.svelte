<script>
  import { Button } from "$lib/components/ui/button";
  import { createWizardFlow, stepBar } from "$lib/wizardFlow.js";
  import { t } from "$lib/i18n.js";

  // Windows onboarding — separate component, not a branch inside the
  // macOS Wizard.svelte (2026-08-26, W1 real-box run: 用户明确要求整块
  // 按环境拆分，而不是在同一份文案里堆 if windows/else). Copy differs
  // wherever the OS differs (Finder vs 文件资源管理器, TCC-protected
  // 桌面/文稿 vs Windows 没有等价保护目录, macOS Gatekeeper 右键打开 vs
  // Windows SmartScreen "更多信息→仍要运行"). The step machine and the
  // shared actions (chooseFolder, finishSetup's readiness poll) live in
  // $lib/wizardFlow.js (#1045) — this view only keeps its own copy and
  // the Windows step 2 (the daemon keeps the machine awake, nothing to do).
  // DESK-15：按钮视觉合同收进 Button 组件本身，见 Wizard.svelte 同条注释。
  const WIZARD_PRIMARY_WIDE = "px-[26px]";

  let { defaultDir, configuredLibraryDir, unconfigured = false, onDone } = $props();

  let view = $state({ step: 1, libraryDir: "", busy: false, error: "" });
  const flow = createWizardFlow({
    defaultDir,
    configuredLibraryDir,
    onDone,
    onChange: (patch) => Object.assign(view, patch),
  });
  Object.assign(view, flow.snapshot());
</script>

<div class="mt-4 flex flex-col gap-[22px] rounded-xl border border-border bg-paper px-8 py-7">
  <div class="flex gap-2">
    {#each stepBar(view.step) as s}
      <span class="text-[13px] font-semibold {s.state === 'current' ? 'text-ink' : s.state === 'done' ? 'text-safe' : 'text-ink-40'}">
        {s.n}. {s.label}
      </span>
    {/each}
  </div>

  {#if view.error}
    <p class="m-0 rounded-md bg-act-bg px-[14px] py-[10px] text-[15px] text-act">{view.error}</p>
  {/if}

  {#if view.step === 1}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_library_title")}</h2>
      <!-- #1115：后台服务在跑、只是还没有照片库位置——说清楚，别让人以为服务挂了。 -->
      {#if unconfigured}
        <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[14px] leading-[1.6] text-ink" data-testid="wizard-unconfigured">{t("ui.wizard_unconfigured_notice")}</p>
      {/if}
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_library_body_win")}</p>
      <div class="flex items-center gap-[10px]">
        <code class="flex-1 rounded-xl bg-linen px-4 py-[13px] font-mono text-[14px] text-ink-60 break-all">{view.libraryDir}</code>
        <Button variant="secondary" class="flex-none" onclick={flow.chooseFolder}>{t("ui.wizard_change_folder")}</Button>
      </div>
      {#if view.libraryDir !== defaultDir}
        <Button variant="link" tone="safe" class="self-start" onclick={flow.useDefault} title={t("ui.wizard_use_default")}>↺ {t("ui.wizard_use_default")}</Button>
      {/if}
      <!-- Windows 没有 macOS TCC 那样的系统级保护目录弹窗；真正的坑是系统盘
           受保护路径（Program Files 等）权限受限、云盘同步目录（OneDrive
           等）可能带来重复占用/同步冲突。默认路径落在用户的「图片」目录，
           不需要额外提醒，只在选到明显有风险的地方才提示。 -->
      <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[13.5px] leading-[1.6] text-ink-60">{t("ui.wizard_library_tip_win")}</p>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <span></span>
      <Button class={WIZARD_PRIMARY_WIDE} disabled={!view.libraryDir || view.busy} onclick={flow.toStep2}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if view.step === 2}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_sleep_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_sleep_body")}</p>
      <!-- DAE-11 (#804)：不再「一键关闭自动睡眠」（要 UAC、永久改用户的电源设置、
           只设了插电）。改由 daemon 运行且插电时向系统声明别因空闲而睡——不用授权，
           屏幕照常熄灭锁屏，服务一停声明就失效。所以这一步只需说明，不用检测也不用点。 -->
      <div class="flex items-center gap-3 rounded-xl border border-border px-[18px] py-[14px]">
        <span class="h-[9px] w-[9px] flex-none rounded-full bg-safe"></span>
        <span class="flex-1 text-[14px] leading-[1.6]">{t("ui.wizard_sleep_auto_win")}</span>
      </div>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <Button variant="link" onclick={flow.back}>‹ {t("ui.wizard_back")}</Button>
      <Button class={WIZARD_PRIMARY_WIDE} onclick={flow.toStep3}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if view.step === 3}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_service_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_service_body")}</p>
      <div class="rounded-xl border border-border">
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_asks_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_asks_win")}</span>
        </div>
        <div class="flex gap-3 px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_blocked_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_blocked_win")}</span>
        </div>
      </div>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <Button variant="link" onclick={flow.back}>‹ {t("ui.wizard_back")}</Button>
      <Button class={WIZARD_PRIMARY_WIDE} disabled={view.busy} onclick={flow.finishSetup}>
        {view.busy ? t("ui.starting") : t("ui.wizard_finish")}
      </Button>
    </div>
  {/if}
</div>
