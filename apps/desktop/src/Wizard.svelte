<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import QRCode from "qrcode";

  let { defaultDir, configuredLibraryDir, onDone } = $props();

  let step = $state(1);
  // T-042b: 若 config 已指向某库（oneshot 降级/中途退出回 wizard），预填它——
  // 用户直接"下一步"不会把库改到新空目录（孤儿库风险）。
  let libraryDir = $state(configuredLibraryDir ?? "");
  let power = $state(null); // {kind, minutes}
  let qrDataUrl = $state("");
  let qrText = $state("");
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
    error = "";
    busy = true;
    try {
      const mode = await invoke("start_daemon");
      console.log("daemon mode:", mode);
      // Wait for the daemon to come up, then fetch a pairing QR.
      let qr = "";
      for (let i = 0; i < 20; i++) {
        await new Promise((r) => setTimeout(r, 500));
        try {
          const r = await invoke("daemon_call", { method: "pairing.start", params: {} });
          qr = r.qr;
          break;
        } catch (_) {}
      }
      if (!qr) throw new Error("后台服务没有在 10 秒内就绪");
      qrText = qr;
      qrDataUrl = await QRCode.toDataURL(qr, { width: 240, margin: 1 });
      step = 3;
    } catch (e) {
      error = `启动后台服务失败：${e}`;
    } finally {
      busy = false;
    }
  }
</script>

<div class="wizard">
  <div class="steps">
    {#each ["选择照片位置", "电源检查", "添加手机"] as label, i}
      <span class="step" class:active={step === i + 1} class:done={step > i + 1}>
        {i + 1}. {label}
      </span>
    {/each}
  </div>

  {#if error}
    <p class="error">{error}</p>
  {/if}

  {#if step === 1}
    <h2>照片存到哪里？</h2>
    <p class="hint">家人手机备份的照片和视频会以普通文件保存在这个文件夹里——用访达也能直接看到，随时可以整体拷走。</p>
    {#if libraryDir}
      <p class="chosen">已选择：<code>{libraryDir}</code></p>
    {/if}
    <div class="row">
      <button class="primary" onclick={chooseFolder}>选择文件夹…</button>
      <button onclick={useDefault}>用默认位置</button>
    </div>
    {#if !libraryDir}
      <p class="hint">默认位置：<code>{defaultDir}</code></p>
    {/if}
    <div class="nav">
      <button class="primary" disabled={!libraryDir || busy} onclick={toStep2}>下一步</button>
    </div>
  {:else if step === 2}
    <h2>电脑会睡着吗？</h2>
    {#if power?.kind === "never"}
      <p class="ok-box">✓ 这台电脑设置为不自动休眠——备份随时都能进行，无需调整。</p>
    {:else if power?.kind === "sleeps"}
      <p class="warn-box">
        这台电脑闲置 {power.minutes} 分钟后会休眠。备份进行中我们会自动保持它清醒；
        但如果你希望家人<strong>随时</strong>都能翻看照片，建议把「关闭显示器后仍保持唤醒」打开。
      </p>
      <button onclick={() => invoke("open_power_settings")}>打开系统电源设置…</button>
    {:else}
      <p class="hint">没能读到这台电脑的电源策略（不影响使用）：备份进行中我们会自动保持它清醒。</p>
    {/if}
    {#if true}
      <p class="hint">下一步会把 P-Pass 后台服务注册为系统常驻服务：开机自动运行、意外退出自动恢复——之后你永远不需要手动启动它。</p>
    {/if}
    <div class="nav">
      <button onclick={() => (step = 1)}>上一步</button>
      <button class="primary" disabled={busy} onclick={toStep3}>
        {busy ? "正在设置后台服务…" : "设为常驻服务并继续"}
      </button>
    </div>
  {:else}
    <h2>用手机扫码加入</h2>
    <p class="hint">在手机上打开 P-Pass App，扫描下面的二维码；手机发来的加入请求会出现在本窗口，点「允许」即可。</p>
    {#if qrDataUrl}
      <img class="qr" src={qrDataUrl} alt="配对二维码" />
      <details>
        <summary>无法扫码？复制配对串</summary>
        <code class="qrtext">{qrText}</code>
      </details>
    {/if}
    <div class="nav">
      <button class="primary" onclick={onDone}>完成</button>
    </div>
  {/if}
</div>

<style>
  /* Colours/typography from assets/design/tokens.css. */
  .wizard {
    background: var(--pp-paper);
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-card);
    padding: 24px;
    margin-top: 16px;
  }
  .steps {
    display: flex;
    gap: 16px;
    margin-bottom: 18px;
  }
  .step {
    font-size: 13px;
    font-weight: 600;
    color: var(--pp-ink-40);
  }
  .step.active {
    color: var(--pp-ink);
  }
  .step.done {
    color: var(--pp-safe);
  }
  h2 {
    font-family: var(--pp-font-serif);
    font-size: 26px;
    font-weight: 400;
    margin: 0 0 10px;
  }
  .hint {
    color: var(--pp-ink-40);
    font-size: 14px;
    line-height: 1.55;
  }
  .chosen {
    font-size: 15px;
  }
  .row {
    display: flex;
    gap: 10px;
    margin: 12px 0;
  }
  .nav {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    margin-top: 22px;
    padding-top: 18px;
    border-top: 1px solid var(--pp-divider);
  }
  button {
    min-height: var(--pp-tap-min);
    border: 1.5px solid var(--pp-border-strong);
    background: transparent;
    border-radius: var(--pp-radius-control);
    padding: 0 18px;
    cursor: pointer;
    font-family: inherit;
    font-size: 15px;
    font-weight: 600;
    color: var(--pp-ink-60);
  }
  button:hover {
    background: var(--pp-linen);
  }
  button.primary {
    background: var(--pp-ink);
    border-color: var(--pp-ink);
    color: var(--pp-paper);
    font-weight: 700;
  }
  button.primary:hover {
    background: var(--pp-ink-hover);
  }
  button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .ok-box {
    background: var(--pp-safe-bg);
    color: var(--pp-safe);
    border-radius: var(--pp-radius-control);
    padding: 12px 14px;
    font-size: 15px;
    line-height: 1.5;
  }
  .warn-box {
    background: var(--pp-waiting-bg);
    color: var(--pp-ink-60);
    border-radius: var(--pp-radius-control);
    padding: 12px 14px;
    font-size: 15px;
    line-height: 1.55;
  }
  .error {
    background: var(--pp-act-bg);
    color: var(--pp-act);
    border-radius: var(--pp-radius-control);
    padding: 10px 14px;
    font-size: 15px;
  }
  .qr {
    display: block;
    margin: 12px 0 4px;
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-card);
  }
  .qrtext {
    display: block;
    word-break: break-all;
    font-size: 12px;
    background: var(--pp-linen);
    padding: 10px;
    border-radius: var(--pp-radius-control-sm);
    margin-top: 6px;
  }
</style>
