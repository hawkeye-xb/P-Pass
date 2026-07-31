<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import QRCode from "qrcode";

  let { defaultDir, onDone } = $props();

  let step = $state(1);
  let libraryDir = $state("");
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
  .wizard {
    background: #fff;
    border-radius: 10px;
    padding: 20px;
    margin-top: 14px;
    box-shadow: 0 1px 3px rgba(16, 33, 60, 0.08);
  }
  .steps {
    display: flex;
    gap: 14px;
    margin-bottom: 16px;
  }
  .step {
    font-size: 12px;
    color: #9aa4b0;
  }
  .step.active {
    color: #12408f;
    font-weight: 600;
  }
  .step.done {
    color: #14683a;
  }
  h2 {
    font-size: 17px;
    margin: 0 0 8px;
  }
  .hint {
    color: #6b7684;
    font-size: 13px;
  }
  .chosen {
    font-size: 13px;
  }
  .row {
    display: flex;
    gap: 10px;
    margin: 10px 0;
  }
  .nav {
    display: flex;
    justify-content: flex-end;
    gap: 10px;
    margin-top: 18px;
  }
  button {
    border: 1px solid #c4ccd6;
    background: #fff;
    border-radius: 8px;
    padding: 7px 14px;
    cursor: pointer;
    font-size: 13px;
  }
  button.primary {
    background: #12408f;
    border-color: #12408f;
    color: #fff;
  }
  button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  .ok-box {
    background: #d9f2e2;
    color: #14683a;
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 13px;
  }
  .warn-box {
    background: #fff3d6;
    color: #7a5b12;
    border-radius: 8px;
    padding: 10px 12px;
    font-size: 13px;
  }
  .error {
    background: #fbe1e1;
    color: #8f1d1d;
    border-radius: 8px;
    padding: 8px 12px;
    font-size: 13px;
  }
  .qr {
    display: block;
    margin: 12px 0 4px;
    border: 1px solid #e2e7ee;
    border-radius: 8px;
  }
  .qrtext {
    display: block;
    word-break: break-all;
    font-size: 11px;
    background: #f0f3f7;
    padding: 8px;
    border-radius: 6px;
    margin-top: 6px;
  }
</style>
