<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { Button } from "$lib/components/ui/button";
  import { startupFailureText } from "$lib/daemonStartupError.js";

  // Windows onboarding — separate component, not a branch inside the
  // macOS Wizard.svelte (2026-08-26, W1 real-box run: 用户明确要求整块
  // 按环境拆分，而不是在同一份文案里堆 if windows/else). Copy differs
  // wherever the OS differs (Finder vs 文件资源管理器, TCC-protected
  // 桌面/文稿 vs Windows 没有等价保护目录, macOS Gatekeeper 右键打开 vs
  // Windows SmartScreen "更多信息→仍要运行"). Structure/steps/state
  // machine mirror Wizard.svelte on purpose so the two stay easy to
  // diff when a shared behavior (e.g. finishSetup's readiness poll)
  // changes on one side and needs porting to the other.
  const BTN =
    "h-11 min-h-11 rounded-md border border-ink px-[26px] text-[15px] font-bold hover:bg-ink-hover";
  const BTN_OUTLINE =
    "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-transparent px-[18px] text-[15px] font-semibold text-ink-60 hover:bg-linen hover:text-ink-60";
  const BTN_LINK =
    "h-auto min-h-0 rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px]";

  let { defaultDir, configuredLibraryDir, onDone } = $props();

  let step = $state(1);
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

  let sleepFixBusy = $state(false);
  let sleepFixError = $state("");
  async function fixAutoSleep() {
    sleepFixBusy = true;
    sleepFixError = "";
    try {
      await invoke("disable_auto_sleep");
      power = await invoke("power_hint");
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
          startupFailureText(stderr) || "后台服务未能启动。请检查后台服务日志。",
        );
      }
      onDone();
    } catch (e) {
      error = `启动后台服务失败：${e}`;
    } finally {
      busy = false;
    }
  }
</script>

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
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">选一个文件夹当「照片库」。照片会按原始文件存进去，你随时能在文件资源管理器里翻到它们。</p>
      <div class="flex items-center gap-[10px]">
        <code class="flex-1 rounded-xl bg-linen px-4 py-[13px] font-mono text-[14px] text-ink-60 break-all">{libraryDir}</code>
        <Button variant="outline" class="{BTN_OUTLINE} flex-none" onclick={chooseFolder}>更改…</Button>
      </div>
      {#if libraryDir !== defaultDir}
        <button class="self-start {BTN_LINK} text-safe hover:text-safe" onclick={useDefault} title="回到默认位置">↺ 回到默认位置</button>
      {/if}
      <!-- Windows 没有 macOS TCC 那样的系统级保护目录弹窗；真正的坑是系统盘
           受保护路径（Program Files 等）权限受限、云盘同步目录（OneDrive
           等）可能带来重复占用/同步冲突。默认路径落在用户的「图片」目录，
           不需要额外提醒，只在选到明显有风险的地方才提示。 -->
      <p class="m-0 rounded-xl bg-waiting-bg px-4 py-3 text-[13.5px] leading-[1.6] text-ink-60">建议避开系统盘的「Program Files」等受保护目录，也尽量不要选在 OneDrive 等云同步文件夹里——放在「图片」「文档」这类你自己的用户目录下最省心。</p>
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
          <div class="flex items-center gap-[10px]">
            <Button class="{BTN} h-10 min-h-10 flex-none text-[14px]" disabled={sleepFixBusy} onclick={fixAutoSleep}>
              {sleepFixBusy ? "设置中…" : "一键设置"}
            </Button>
            <Button variant="outline" class="{BTN_OUTLINE} h-10 min-h-10 flex-none text-[14px]" onclick={() => invoke("open_power_settings")}>去系统设置</Button>
          </div>
          {#if sleepFixError}
            <p class="m-0 text-[13px] text-act">{sleepFixError}——你也可以点「去系统设置」自己关：打开「电源和睡眠设置」，把「屏幕和睡眠」都改成「从不」。</p>
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
    <div class="flex flex-col gap-4">
      <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">最后一步：设为常驻服务。</h2>
      <p class="m-0 text-[15px] leading-[1.7] text-ink-60">P-Pass 会注册为系统后台服务：开机自动运行，关掉这个窗口也在安静地收备份。随时可以在「设置」里停止它。</p>
      <div class="rounded-xl border border-border">
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">会申请什么</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">开机自启（注册表「启动项」，不需要管理员权限，也不会创建 Windows 服务）</span>
        </div>
        <div class="flex gap-3 border-b border-divider px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">不会做什么</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">不上传到任何云端、不建账号——照片只在你家的设备之间走</span>
        </div>
        <div class="flex gap-3 px-[18px] py-[13px]">
          <span class="w-[120px] flex-none text-[14px] font-semibold text-ink-60">如果被拦</span>
          <span class="text-[14px] leading-[1.5] text-ink-60">安装时若出现 Windows SmartScreen 提示「Windows 已保护你的电脑」：点「更多信息」→「仍要运行」即可（未签名安装包目前会出现这条提示，属已知状态）</span>
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
