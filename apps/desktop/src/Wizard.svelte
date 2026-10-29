<script>
  import { invoke } from "@tauri-apps/api/core";
  import { Button } from "$lib/components/ui/button";
  import { errCodeLine, errMessage, t } from "$lib/i18n.js";
  import { createWizardFlow, stepBar } from "$lib/wizardFlow.js";

  // DESK-15：按钮视觉合同收进 Button 组件本身（primary/secondary/danger/
  // link variant），本页只保留一个真实的版式例外——向导主按钮比全站其它
  // 主按钮更宽（px-[26px] vs 组件默认 18px），两个向导页一致，是有意的。
  const WIZARD_PRIMARY_WIDE = "px-[26px]";

  let { defaultDir, configuredLibraryDir, unconfigured = false, onDone } = $props();

  // 三步状态机（选库 / 睡眠 / 常驻服务）与 chooseFolder、finishSetup 都在
  // $lib/wizardFlow.js，两份向导共用（#1045）；本视图只保留 macOS 的文案和
  // 第 2 步（电源状态）。
  let view = $state({ step: 1, libraryDir: "", busy: false, error: "" });
  let power = $state(null); // {kind, minutes}
  const flow = createWizardFlow({
    defaultDir,
    configuredLibraryDir,
    onDone,
    onChange: (patch) => Object.assign(view, patch),
    // 进第 2 步前问一次电源状态，第 2 步据此渲染。
    beforeStep2: async () => {
      power = await invoke("power_hint");
    },
  });
  Object.assign(view, flow.snapshot());

  // 2026-08-17：一键关闭自动睡眠——独立的 busy/error 状态，不复用向导
  // 全局 busy（那个会连累"继续"按钮跟着置灰，这里只是个局部小动作）。
  let sleepFixBusy = $state(false);
  let sleepFixError = $state(null); // B13：{ text, code }
  async function fixAutoSleep() {
    sleepFixBusy = true;
    sleepFixError = null;
    try {
      await invoke("disable_auto_sleep");
      power = await invoke("power_hint"); // 刷新，成功的话这里应该变成 never
    } catch (e) {
      sleepFixError = errMessage(e, "ui.wizard_sleep_fix_failed_mac");
    } finally {
      sleepFixBusy = false;
    }
  }
</script>

<!-- 2026-08-17：整页对齐设计稿 v2（用户实测反馈"onboarding 整个流程
     UI 都不对"——此前 DESK-07/08 只迁了 App.svelte 的五个主页面，向导
     组件一直是迁移前的手写 CSS，字号/按钮样式/间距跟主界面已经不是
     一套体系）。外层 wizard-shell 已有 padding 24 + max-width 680，
     这里卡片自身 padding 用 32/28（不是设计稿原始 44/34）——设计稿那份
     mock 是独立 680 宽窗口，我们是嵌套在 wizard-shell 里，照抄 44 会
     产生双重内边距，按比例收窄更合理。
     2026-08-17（续）：向导收缩成 3 步——原第 4 步「扫码」整个删掉，
     总览页本来就有常驻的"添加设备"卡片（不受配对状态影响一直显示），
     没必要在向导里重复一份配对 UI；第 3 步「完成」直接 onDone() 进
     主界面，用户落地总览页自然看得到那张卡片。 -->
<div class="mt-4 flex flex-col gap-[22px] rounded-xl border border-border bg-paper px-8 py-7">
  <div class="flex gap-2">
    {#each stepBar(view.step) as s}
      <span class="text-[13px] font-semibold {s.state === 'current' ? 'text-ink' : s.state === 'done' ? 'text-safe' : 'text-ink-40'}">
        {s.n}. {s.label}
      </span>
    {/each}
  </div>

  {#if view.error}
    <p class="m-0 rounded-md bg-act-bg px-[14px] py-[10px] text-[15px] text-act">
      {view.error.text}<span class="mt-[2px] block text-[12px] opacity-80">{errCodeLine(view.error)}</span>
    </p>
  {/if}

  {#if view.step === 1}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_library_title")}</h2>
      <!-- #1115：后台服务在跑、只是还没有照片库位置——说清楚，别让人以为服务挂了。 -->
      {#if unconfigured}
        <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[14px] leading-[1.6] text-ink" data-testid="wizard-unconfigured">{t("ui.wizard_unconfigured_notice")}</p>
      {/if}
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_library_body_mac")}</p>
      <!-- DESK-05: 路径始终有值（默认填充 defaultDir / 预填已配置库）——
           不再要求先点按钮才能继续。路径 ≠ 默认时旁挂「回到默认」链接，
           路径 = 默认时不显示（没有可回退的目标）。 -->
      <div class="flex items-center gap-[10px]">
        <code class="flex-1 rounded-xl bg-linen px-4 py-[13px] font-mono text-[14px] text-ink-60 break-all">{view.libraryDir}</code>
        <Button variant="secondary" class="flex-none" onclick={flow.chooseFolder}>{t("ui.wizard_change_folder")}</Button>
      </div>
      {#if view.libraryDir !== defaultDir}
        <Button variant="link" tone="safe" class="self-start" onclick={flow.useDefault} title={t("ui.wizard_use_default")}>↺ {t("ui.wizard_use_default")}</Button>
      {/if}
      <!-- 设计稿 v2：TCC 保护目录提醒——「桌面」「文稿」受 macOS 保护会
           额外弹一次权限申请，放不下时也更难搬家。 -->
      <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[13.5px] leading-[1.6] text-ink-60">{t("ui.wizard_library_tip_mac")}</p>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <span></span>
      <Button class={WIZARD_PRIMARY_WIDE} disabled={!view.libraryDir || view.busy} onclick={flow.toStep2}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if view.step === 2}
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
          <!-- 2026-08-17：一键设置为主选项（系统原生管理员授权弹窗，不是
               终端）——用户实测反馈系统设置里这个开关根本不在明面上，
               不同 macOS 版本/机型入口还不一样，与其让人自己找菜单，不如
               弹系统授权直接帮着改；不想授权的人保留手动入口退路。 -->
          <div class="flex items-center gap-[10px]">
            <Button size="compact" disabled={sleepFixBusy} onclick={fixAutoSleep}>
              {sleepFixBusy ? t("ui.wizard_sleep_fixing") : t("ui.wizard_sleep_fix")}
            </Button>
            <Button variant="secondary" size="compact" onclick={() => invoke("open_power_settings")}>{t("ui.wizard_open_power_settings")}</Button>
          </div>
          <!-- B3：点「关闭自动睡眠」会弹系统管理员授权框，先说清要输入登录密码（本视图只在 macOS）。 -->
          <p class="m-0 text-[13px] leading-[1.5] text-ink-60">{t("ui.wizard_sleep_fix_needs_password")}</p>
          {#if sleepFixError}
            <p class="m-0 text-[13px] text-act">
              {sleepFixError.text}<span class="mt-[2px] block text-[12px] opacity-80">{errCodeLine(sleepFixError)}</span>
            </p>
          {/if}
        </div>
      {:else}
        <p class="m-0 text-[13px] leading-[1.6] text-ink-40">{t("ui.wizard_power_unknown")}</p>
      {/if}
    </div>
    <div class="mt-auto flex items-center justify-between">
      <Button variant="link" onclick={flow.back}>‹ {t("ui.wizard_back")}</Button>
      <Button class={WIZARD_PRIMARY_WIDE} onclick={flow.toStep3}>{t("ui.wizard_continue")}</Button>
    </div>
  {:else if view.step === 3}
    <!-- 设计稿 v2：第 3 步 = 「设为常驻服务」——先讲清会弹什么（#481：
         开机自启通知 + 本地网络授权弹窗）/不会做什么（B1 起不再写「如果被拦」，拦截说明在官网下载页），点「完成」才真正启动 daemon（含 autostart
         注册，finishSetup）。 -->
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.wizard_service_title")}</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">{t("ui.wizard_service_body")}</p>
      <!-- 设计稿 v2："标签(120px)+说明"的表格式布局（#481 起四行），不是
           各自独立的卡片——分隔线贴边，跟其它页面的 list-card 同款。 -->
      <div class="rounded-xl border border-border">
        <!-- #481：点「完成」后 macOS 实际会出现两样东西，分两行如实写：
             开机自启只是一条通知（不用批准）；本地网络是真正要用户点
             「允许」的系统弹窗（新构建的 daemon 一启动就弹，系统显示的名字
             是 ppf-daemon 而不是 P-Pass——0.6.1-test.1 实测；finishSetup
             不等弹窗处理完就 onDone() 进首页）。拒绝后 LAN 直连被挡，生产配置带中继
             （TransportConfig::from_endpoints，n0_services=true），所以写
             「只能经中继」而不是「连不上」。恢复入口是静态指引，不做
             拒绝探测（理由见 #481 PR）。 -->
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_notice_only_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_autostart_notice_mac")}</span>
        </div>
        <div class="flex gap-3 px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">{t("ui.wizard_allow_label")}</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">{t("ui.wizard_local_network_mac")}</span>
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
