<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { Button } from "$lib/components/ui/button";

  // 2026-08-17：向导页对齐设计稿 v2 重写——跟 App.svelte 迁移页同款
  // 按钮族常量（BTN=主按钮 ink 底纸字，BTN_OUTLINE=次按钮透明底描边，
  // BTN_LINK=纯文字链接），保证全站按钮视觉一致，不重复定义新样式。
  const BTN =
    "h-11 min-h-11 rounded-md border border-ink px-[26px] text-[15px] font-bold hover:bg-ink-hover";
  const BTN_OUTLINE =
    "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-transparent px-[18px] text-[15px] font-semibold text-ink-60 hover:bg-linen hover:text-ink-60";
  const BTN_LINK =
    "h-auto min-h-0 rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px]";

  let { defaultDir, configuredLibraryDir, onDone } = $props();

  let step = $state(1);
  // T-042b: 若 config 已指向某库（oneshot 降级/中途退出回 wizard），预填它——
  // 用户直接"下一步"不会把库改到新空目录（孤儿库风险）。
  // DESK-05: 新装时默认填充 defaultDir——不再要求先点「用默认位置」才能
  // 继续；选了别的文件夹后路径旁出现「回到默认」按钮。
  let libraryDir = $state(configuredLibraryDir || defaultDir);
  let power = $state(null); // {kind, minutes}
  let busy = $state(false);
  let error = $state("");

  async function chooseFolder() {
    const dir = await openDialog({
      directory: true,
      title: "选择照片存放的文件夹",
      defaultPath: defaultDir,
    });
    if (dir) libraryDir = dir;
  }

  function useDefault() {
    libraryDir = defaultDir;
  }

  // 2026-08-17：一键关闭自动睡眠——独立的 busy/error 状态，不复用向导
  // 全局 busy（那个会连累"继续"按钮跟着置灰，这里只是个局部小动作）。
  let sleepFixBusy = $state(false);
  let sleepFixError = $state("");
  async function fixAutoSleep() {
    sleepFixBusy = true;
    sleepFixError = "";
    try {
      await invoke("disable_auto_sleep");
      power = await invoke("power_hint"); // 刷新，成功的话这里应该变成 never
    } catch (e) {
      sleepFixError = String(e);
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
      error = `保存设置失败：${e}`;
    } finally {
      busy = false;
    }
  }

  async function toStep3() {
    // 设计稿 v2：第 3 步 = 「设为常驻服务」说明页——先讲清楚会申请什么/
    // 不会做什么/被拦怎么办，再动手。真正的 start_daemon（含 autostart
    // 注册）在用户点「完成」的 finishSetup 里才执行。
    step = 3;
  }

  // 2026-08-17：第 3 步完成 = 整个 onboarding 完成，不再单开第 4 步扫码
  // 页——总览页本来就有常驻的"添加设备"卡片（含"显示配对二维码"
  // 按钮，不受配对状态影响一直显示），用户落地主界面自然看得到，不需要
  // 在向导里重复一遍相同的能力。启动 daemon（此刻才注册开机自启）→
  // 轮询 status 确认真的就绪（不然主界面会闪一下"服务未连接"）→ 直接
  // onDone() 进主界面。
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
      if (!ready) throw new Error("后台服务没有在 10 秒内就绪");
      onDone();
    } catch (e) {
      error = `启动后台服务失败：${e}`;
    } finally {
      busy = false;
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
    {#each ["照片存在哪", "电脑会睡吗", "设为常驻服务"] as label, i}
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
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">全家的照片，要存到哪里？</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">选一个文件夹当「照片库」。照片会按原始文件存进去，你随时能在 Finder 里翻到它们。</p>
      <!-- DESK-05: 路径始终有值（默认填充 defaultDir / 预填已配置库）——
           不再要求先点按钮才能继续。路径 ≠ 默认时旁挂「回到默认」链接，
           路径 = 默认时不显示（没有可回退的目标）。 -->
      <div class="flex items-center gap-[10px]">
        <code class="flex-1 rounded-xl bg-linen px-4 py-[13px] font-mono text-[14px] text-ink-60 break-all">{libraryDir}</code>
        <Button variant="outline" class="{BTN_OUTLINE} flex-none" onclick={chooseFolder}>更改…</Button>
      </div>
      {#if libraryDir !== defaultDir}
        <button class="self-start {BTN_LINK} text-safe hover:text-safe" onclick={useDefault} title="回到默认位置">↺ 回到默认位置</button>
      {/if}
      <!-- 设计稿 v2：TCC 保护目录提醒——「桌面」「文稿」受 macOS 保护会
           额外弹一次权限申请，放不下时也更难搬家。 -->
      <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[13.5px] leading-[1.6] text-ink-60">建议避开「桌面」和「文稿」——它们受 macOS 系统保护，会额外弹一次权限申请；放不下时也更难搬家。</p>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <span></span>
      <Button class={BTN} disabled={!libraryDir || busy} onclick={toStep2}>继续</Button>
    </div>
  {:else if step === 2}
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">让这台电脑保持醒着。</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">家人手机会趁插电连 Wi-Fi 时把照片传回来——电脑得开着才收得到。</p>
      {#if power?.kind === "never"}
        <div class="flex items-center gap-3 rounded-xl border border-border px-[18px] py-[14px]">
          <span class="h-[9px] w-[9px] flex-none rounded-full bg-safe"></span>
          <span class="flex-1 text-[15px] font-semibold">这台电脑设置为不自动休眠</span>
          <span class="text-[13px] text-safe">✓ 检查通过</span>
        </div>
      {:else if power?.kind === "sleeps"}
        <div class="flex flex-col gap-3 rounded-xl border border-border bg-waiting-bg px-[18px] py-[14px]">
          <div class="flex items-center gap-3">
            <span class="h-[9px] w-[9px] flex-none rounded-full bg-waiting"></span>
            <div class="flex-1">
              <p class="m-0 text-[15px] font-semibold">「自动睡眠」还开着</p>
              <p class="m-0 mt-[3px] text-[13px] leading-[1.5] text-ink-60">
                这台电脑闲置 {power.minutes} 分钟后会休眠，睡着时收不了备份。
              </p>
            </div>
          </div>
          <!-- 2026-08-17：一键设置为主选项（系统原生管理员授权弹窗，不是
               终端）——用户实测反馈系统设置里这个开关根本不在明面上，
               不同 macOS 版本/机型入口还不一样，与其让人自己找菜单，不如
               弹系统授权直接帮着改；不想授权的人保留手动入口退路。 -->
          <div class="flex items-center gap-[10px]">
            <Button class="{BTN} h-10 min-h-10 flex-none text-[14px]" disabled={sleepFixBusy} onclick={fixAutoSleep}>
              {sleepFixBusy ? "设置中…" : "一键设置"}
            </Button>
            <Button variant="outline" class="{BTN_OUTLINE} h-10 min-h-10 flex-none text-[14px]" onclick={() => invoke("open_power_settings")}>去系统设置</Button>
          </div>
          {#if sleepFixError}
            <p class="m-0 text-[13px] text-act">{sleepFixError}——你也可以点「去系统设置」自己关：打开后在右上角搜索框搜「睡眠」最快，不同 macOS 版本菜单位置不一样。</p>
          {/if}
        </div>
      {:else}
        <p class="m-0 text-[13px] leading-[1.6] text-ink-40">没能读到这台电脑的电源策略（不影响使用）：备份进行中我们会自动保持它清醒。</p>
      {/if}
    </div>
    <div class="mt-auto flex items-center justify-between">
      <button class={BTN_LINK} onclick={() => (step = 1)}>‹ 上一步</button>
      <Button class={BTN} onclick={toStep3}>继续</Button>
    </div>
  {:else if step === 3}
    <!-- 设计稿 v2：第 3 步 = 「设为常驻服务」——先讲清会申请什么/不会
         做什么/被拦怎么办，点「完成」才真正启动 daemon（含 autostart
         注册，finishSetup）。 -->
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">最后一步：设为常驻服务。</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">P-Pass 会注册为系统后台服务：开机自动运行，关掉这个窗口也在安静地收备份。随时可以在「设置」里停止它。</p>
      <!-- 设计稿 v2：三行"标签(120px)+说明"的表格式布局，不是三个
           各自独立的卡片——分隔线贴边，跟其它页面的 list-card 同款。 -->
      <div class="rounded-xl border border-border">
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">会申请什么</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">开机自启（系统会弹一次「后台项目已添加」通知，是正常的）</span>
        </div>
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">不会做什么</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">不上传到任何云端、不建账号——照片只在你家的设备之间走</span>
        </div>
        <div class="flex gap-3 px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">如果被拦</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">首次打开被 macOS 拦截时：右键点 App → 打开（只需一次）</span>
        </div>
      </div>
    </div>
    <div class="mt-auto flex items-center justify-between">
      <button class={BTN_LINK} onclick={() => (step = 2)}>‹ 上一步</button>
      <Button class={BTN} disabled={busy} onclick={finishSetup}>
        {busy ? "正在启动…" : "完成"}
      </Button>
    </div>
  {/if}
</div>
