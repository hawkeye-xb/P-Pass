<script>
  import { invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import QRCode from "qrcode";
  import { onDestroy } from "svelte";

  let { defaultDir, configuredLibraryDir, onDone } = $props();

  let step = $state(1);
  // T-042b: 若 config 已指向某库（oneshot 降级/中途退出回 wizard），预填它——
  // 用户直接"下一步"不会把库改到新空目录（孤儿库风险）。
  // DESK-05: 新装时默认填充 defaultDir——不再要求先点「用默认位置」才能
  // 继续；选了别的文件夹后路径旁出现「回到默认」按钮。
  let libraryDir = $state(configuredLibraryDir || defaultDir);
  let power = $state(null); // {kind, minutes}
  let qrDataUrl = $state("");
  let qrText = $state("");
  let busy = $state(false);
  let error = $state("");
  // DESK-04③: 第三步接 T4 新配对弹窗流——扫码后即时切确认列表
  // （IPC-02 事件驱动 + 3s 轮询兜底），不再停留常驻 QR。
  let pendingList = $state([]);
  let pendingTimer = null;
  let unlisten = null;

  async function call(method, params = {}) {
    return await invoke("daemon_call", { method, params });
  }

  // DESK-04③: pending 轮询（3s，比主界面 60s 对账密——wizard 阶段
  // 是配对发生时刻，等 60s 太久；事件驱动命中后立即刷新）。
  async function refreshPending() {
    if (step !== 3) return;
    try {
      const p = await call("pairing.pending", {});
      pendingList = (p.pending ?? []).map((x) =>
        typeof x === "string" ? { name: x, hint_match: null } : x
      );
    } catch (_) {
      // daemon 还没就绪/短暂不可达——下次轮询再试。
    }
  }

  async function confirmPair(accept, name) {
    try {
      await call("pairing.confirm", { accept, device_name: name, merge_node_id: null });
      await refreshPending();
    } catch (e) {
      error = `处理失败：${e}`;
    }
  }

  function startPendingWatch() {
    stopPendingWatch();
    refreshPending();
    pendingTimer = setInterval(refreshPending, 3000);
    listen("daemon-event", onDaemonEvent).then((f) => (unlisten = f));
  }

  function stopPendingWatch() {
    if (pendingTimer) clearInterval(pendingTimer);
    pendingTimer = null;
    if (unlisten) unlisten();
    unlisten = null;
  }

  function onDaemonEvent(ev) {
    const name = ev?.payload?.event;
    if (!name) return;
    refreshPending();
  }

  onDestroy(() => stopPendingWatch());

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

  // H-10b (2026-08-08, xixi): QR 无法刷新——token 10 分钟过期后界面
  // 上没有任何重新生成的入口，只能退出向导重来。抽成 generateQr()
  // 供首次（toStep3）和刷新按钮共用。
  async function generateQr() {
    busy = true;
    error = "";
    try {
      const r = await invoke("daemon_call", { method: "pairing.start", params: {} });
      const qr = r.qr;
      // H-10b: 配对码瘦身后仍在 ~170 字符——渲染加大 + 低纠错（L）保
      // 可扫性（内容长时 L 级比默认 M 级更好扫；三星/鸿蒙取景都实测过）。
      qrText = qr;
      qrDataUrl = await QRCode.toDataURL(qr, {
        width: 320,
        margin: 2,
        errorCorrectionLevel: "L",
      });
      step = 3;
      startPendingWatch();
    } catch (e) {
      error = `生成配对码失败：${e}`;
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
      qrDataUrl = await QRCode.toDataURL(qr, {
        width: 320,
        margin: 2,
        errorCorrectionLevel: "L",
      });
      step = 3;
      startPendingWatch();
    } catch (e) {
      error = `启动后台服务失败：${e}`;
    } finally {
      busy = false;
    }
  }
</script>

<div class="wizard">
  <div class="steps">
    {#each ["照片存在哪", "电脑会睡吗", "加手机"] as label, i}
      <span class="step" class:active={step === i + 1} class:done={step > i + 1}>
        {i + 1}. {label}
      </span>
    {/each}
  </div>

  {#if error}
    <p class="error">{error}</p>
  {/if}

  {#if step === 1}
    <h2>照片存在哪里？</h2>
    <p class="hint">家人手机里的照片和视频会以普通文件保存在这个文件夹里——用电脑自带的文件管理器也能直接看到，随时可以整个拷走。</p>
    <!-- DESK-05: 路径始终有值（默认填充 defaultDir / 预填已配置库）——
         不再要求先点按钮才能继续。路径 ≠ 默认时旁挂「回到默认」按钮，
         路径 = 默认时不显示（没有可回退的目标）。 -->
    <p class="chosen">已选择：<code>{libraryDir}</code>
      {#if libraryDir !== defaultDir}
        <button class="reset-default" onclick={useDefault} title="回到默认位置">↺ 回到默认</button>
      {/if}
    </p>
    <div class="row">
      <button class="primary" onclick={chooseFolder}>选一个文件夹…</button>
    </div>
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
      <p class="hint">下一步会让 P-Pass 开机自动运行、意外退出自动恢复——之后你不需要手动打开它。</p>
    {/if}
    <div class="nav">
      <button onclick={() => (step = 1)}>上一步</button>
      <button class="primary" disabled={busy} onclick={toStep3}>
        {busy ? "正在设置…" : "继续"}
      </button>
    </div>
  {:else if step === 3 && pendingList.length > 0}
    <!-- DESK-04③: 有人扫码 → 即时切确认列表（不再停留常驻 QR）。
         与主界面 T4 模态同语义：逐行允许/拒绝，处理完该行消失。 -->
    <h2>{pendingList.length > 1 ? `有 ${pendingList.length} 台手机请求加入` : "有手机请求加入"}</h2>
    <p class="hint">是家人的手机吗？点「允许」后它就能开始备份照片了。</p>
    <div class="pending-list">
      {#each pendingList as item}
        <div class="pending-row">
          <span class="pending-name">{item.name}</span>
          <div class="pending-actions">
            <button onclick={() => confirmPair(false, item.name)}>拒绝</button>
            <button class="primary" onclick={() => confirmPair(true, item.name)}>允许</button>
          </div>
        </div>
      {/each}
    </div>
  {:else}
    <h2>用手机扫码加入</h2>
    <p class="hint">在手机上打开 P-Pass App，扫描下面的二维码；手机发来的加入请求会立刻出现在这里，点「允许」即可。</p>
    {#if qrDataUrl}
      <img class="qr" src={qrDataUrl} alt="配对二维码" />
      <details>
        <summary>无法扫码？复制配对串</summary>
        <code class="qrtext">{qrText}</code>
      </details>
    {/if}
    <div class="nav">
      <button onclick={generateQr} disabled={busy}>
        {busy ? "正在刷新…" : "刷新二维码"}
      </button>
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
  /* DESK-05: 路径旁「回到默认」小按钮——文本行内，不占独立行。 */
  .chosen .reset-default {
    margin-left: 8px;
    min-height: 0;
    padding: 2px 10px;
    font-size: 13px;
    font-weight: 600;
    border-radius: var(--pp-radius-control-sm, 6px);
    vertical-align: middle;
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
  /* DESK-04③: 确认列表——逐行允许/拒绝，token 同主界面模态。 */
  .pending-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 14px;
  }
  .pending-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    background: var(--pp-linen);
    border-radius: var(--pp-radius-control);
    padding: 10px 14px;
  }
  .pending-name {
    font-size: 15px;
    font-weight: 600;
    color: var(--pp-ink);
  }
  .pending-actions {
    display: flex;
    gap: 8px;
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
