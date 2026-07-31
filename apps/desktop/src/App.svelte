<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog, confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
  import { revealItemInDir } from "@tauri-apps/plugin-opener";
  import QRCode from "qrcode";
  import { onMount, onDestroy } from "svelte";
  import Wizard from "./Wizard.svelte";

  let wizard = $state(null); // null=检测中, {configured, default_dir}
  let starting = $state(false);

  async function checkWizard() {
    wizard = await invoke("wizard_state");
  }

  async function stopService() {
    const yes = await confirmDialog(
      "停止后会取消开机自启并暂停所有备份，家人手机将无法连接，直到你重新启用。确定停止？",
      { title: "停止后台服务", kind: "warning" }
    );
    if (!yes) return;
    try {
      await invoke("stop_daemon");
      message = "后台服务已停止，开机不再自动运行。";
    } catch (e) {
      message = `停止失败：${e}`;
    }
  }

  async function startDaemonNow() {
    starting = true;
    try {
      await invoke("start_daemon");
    } catch (e) {
      message = `启动失败：${e}`;
    } finally {
      setTimeout(() => (starting = false), 3000);
    }
  }

  let online = $state(false);
  let status = $state(null);
  let devices = $state([]);
  let qrDataUrl = $state("");
  let qrText = $state("");
  let message = $state("");
  let pendingCount = $state(0);

  async function call(method, params = {}) {
    return await invoke("daemon_call", { method, params });
  }

  async function refresh() {
    try {
      status = await call("status");
      online = true;
      pendingCount = status.pending_pairs ?? 0;
      const d = await call("devices.list");
      devices = d.devices ?? [];
    } catch (e) {
      online = false;
      status = null;
    }
  }

  async function startPairing() {
    message = "";
    try {
      const r = await call("pairing.start");
      qrText = r.qr;
      qrDataUrl = await QRCode.toDataURL(r.qr, { width: 260, margin: 1 });
    } catch (e) {
      message = `发起配对失败：${e}`;
    }
  }

  async function confirmPair(accept) {
    try {
      const r = await call("pairing.confirm", { accept });
      message = accept ? `已允许「${r.device}」加入` : `已拒绝「${r.device}」`;
      await refresh();
    } catch (e) {
      message = `确认失败：${e}`;
    }
  }

  async function revoke(nodeId, name) {
    const yes = await confirmDialog(`确定移除设备「${name}」？它将立刻失去访问权限。`, {
      title: "移除设备",
      kind: "warning",
    });
    if (!yes) return;
    try {
      await call("device.revoke", { node_id: nodeId });
      message = `已移除「${name}」`;
      await refresh();
    } catch (e) {
      message = `移除失败：${e}`;
    }
  }

  async function openLibrary() {
    try {
      const s = await call("status");
      const dir = s.library_dir;
      if (!dir) throw new Error("后台服务还没报告库位置");
      // originals/ 是照片所在；库刚建还没照片时打开库根目录。
      try {
        await revealItemInDir(`${dir}/originals`);
      } catch (_) {
        await revealItemInDir(dir);
      }
    } catch (e) {
      message = `打开失败：${e}`;
    }
  }

  async function chooseFolder() {
    const dir = await openDialog({ directory: true, title: "选择照片库文件夹" });
    if (!dir) return;
    try {
      await call("folder.set", { path: dir });
      message = `库文件夹已保存为 ${dir}，重启后台服务后生效。`;
    } catch (e) {
      message = `保存失败：${e}`;
    }
  }

  async function exportLogs() {
    try {
      const r = await call("logs.export");
      message = `诊断包已导出（内容已脱敏，可放心外发）：${r.zip}`;
      try {
        await revealItemInDir(r.zip); // 在 Finder/资源管理器中直接展示
      } catch (_) {}
    } catch (e) {
      message = `导出失败：${e}`;
    }
  }

  let timer;
  onMount(() => {
    checkWizard();
    refresh();
    timer = setInterval(refresh, 3000); // 契约: 状态 3s 轮询
  });
  onDestroy(() => clearInterval(timer));

  const stateLabel = $derived(
    !online
      ? "后台服务未运行"
      : {
          ONLINE_DIRECT: "运行中",
          ONLINE_RELAY: "运行中（经中继）",
          PAIRING: "等待配对确认",
          DISK_FULL: "磁盘已满",
          INDEXING: "正在整理照片库",
          STORAGE_OFFLINE: "离线",
        }[status?.state] ?? status?.state
  );
</script>

<main>
  <header>
    <h1>P-Pass</h1>
    <span class="badge" class:ok={online} class:bad={!online}>{stateLabel}</span>
  </header>

  {#if message}
    <p class="message">{message}</p>
  {/if}

  {#if wizard && !wizard.configured && !online}
    <Wizard defaultDir={wizard.default_dir} onDone={() => { checkWizard(); refresh(); }} />
  {:else if !online}
    <section>
      <p>后台服务没有在运行。</p>
      <button class="primary" disabled={starting} onclick={startDaemonNow}>
        {starting ? "正在启动…" : "启动后台服务"}
      </button>
      <p class="hint">启动后本窗口每 3 秒自动刷新。</p>
    </section>
  {:else}
    <section>
      <h2>状态</h2>
      <p>
        已配对设备 {status.devices - status.revoked} 台
        {#if status.revoked > 0}（另有 {status.revoked} 台已移除）{/if}
        {#if pendingCount > 0}<strong>· {pendingCount} 个配对请求待确认</strong>{/if}
      </p>
      {#if pendingCount > 0}
        <div class="row">
          <button class="primary" onclick={() => confirmPair(true)}>允许加入</button>
          <button onclick={() => confirmPair(false)}>拒绝</button>
        </div>
      {/if}
    </section>

    <section>
      <h2>添加设备</h2>
      <div class="row">
        <button class="primary" onclick={startPairing}>生成配对二维码</button>
      </div>
      {#if qrDataUrl}
        <img class="qr" src={qrDataUrl} alt="配对二维码" />
        <details>
          <summary>无法扫码？复制配对串</summary>
          <code class="qrtext">{qrText}</code>
        </details>
        <p class="hint">二维码 10 分钟内有效；扫码后回到本窗口点「允许加入」。</p>
      {/if}
    </section>

    <section>
      <h2>设备</h2>
      {#if devices.length === 0}
        <p class="hint">还没有配对的设备。</p>
      {:else}
        <ul class="devices">
          {#each devices as d}
            <li>
              <span class:revoked={d.revoked}>
                {d.name}
                <small>{d.role}{d.revoked ? " · 已移除" : ""}</small>
              </span>
              {#if !d.revoked}
                <button class="danger" onclick={() => revoke(d.node_id, d.name)}>移除</button>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </section>

    <section>
      <h2>设置</h2>
      <div class="row">
        <button class="primary" onclick={openLibrary}>打开照片文件夹</button>
        <button onclick={chooseFolder}>更改库文件夹…</button>
        <button onclick={exportLogs}>导出诊断包</button>
      </div>
      <p class="hint">诊断包会自动抹去用户名等隐私路径，可安全提供给支持人员。</p>
      <div class="row" style="margin-top:12px">
        <button class="danger" onclick={stopService}>停止后台服务</button>
      </div>
      <p class="hint">停止后开机不再自动运行、备份暂停；重新打开本 App 可再次启用。</p>
    </section>
  {/if}
</main>

<style>
  /* All colours/typography come from assets/design/tokens.css (single
     source of truth). Meaning colours: green=safe, amber=waiting,
     red=act — nothing else carries meaning. */
  :global(body) {
    margin: 0;
    font-family: var(--pp-font-sans);
    background: var(--pp-canvas);
    color: var(--pp-ink);
    font-size: var(--pp-body-min);
  }
  main {
    max-width: 680px;
    margin: 0 auto;
    padding: 24px;
  }
  header {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  h1 {
    font-size: 15px;
    font-weight: 700;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    margin: 0;
  }
  h2 {
    font-family: var(--pp-font-serif);
    font-size: 22px;
    font-weight: 400;
    margin: 0 0 10px;
  }
  section {
    background: var(--pp-paper);
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-card);
    padding: 20px 22px;
    margin-top: 16px;
  }
  .badge {
    font-size: 13px;
    font-weight: 600;
    padding: 6px 14px;
    border-radius: var(--pp-radius-pill);
    background: var(--pp-idle-bg);
    color: var(--pp-ink-60);
  }
  .badge.ok {
    background: var(--pp-safe-bg);
    color: var(--pp-safe);
  }
  .badge.bad {
    background: var(--pp-act-bg);
    color: var(--pp-act);
  }
  .row {
    display: flex;
    gap: 10px;
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
  button.danger {
    color: var(--pp-act);
    border-color: var(--pp-border-strong);
  }
  button.danger:hover {
    border-color: var(--pp-act);
    background: var(--pp-act-bg);
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
  .devices {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .devices li {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 0;
    border-bottom: 1px solid var(--pp-divider);
  }
  .devices li:last-child {
    border-bottom: none;
  }
  .devices small {
    color: var(--pp-ink-40);
    margin-left: 8px;
  }
  .revoked {
    color: var(--pp-ink-40);
    text-decoration: line-through;
  }
  .hint {
    color: var(--pp-ink-40);
    font-size: 14px;
    margin: 10px 0 0;
    line-height: 1.55;
  }
  .message {
    background: var(--pp-waiting-bg);
    border: 1px solid var(--pp-waiting);
    border-radius: var(--pp-radius-control);
    padding: 10px 14px;
    font-size: 15px;
  }
</style>
