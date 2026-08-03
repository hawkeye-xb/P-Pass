<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog, confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
  import { revealItemInDir } from "@tauri-apps/plugin-opener";
  import QRCode from "qrcode";
  import { onMount, onDestroy } from "svelte";
  import Wizard from "./Wizard.svelte";
  // T-072: 状态/错误文案的唯一来源是 diag 字典（crates/diag 注册表 +
  // assets/i18n/*.json，Rust 测试保证双语文案齐全）。直接从仓库根引用，
  // 零副本零漂移；按系统语言选语言表（UI 单语显示的既定决策）。
  import enDict from "../../../assets/i18n/en.json";
  import zhDict from "../../../assets/i18n/zh.json";

  const dict = (navigator.language || "zh").toLowerCase().startsWith("zh") ? zhDict : enDict;
  const t = (key, vars = {}) => {
    let s = dict[key] ?? key;
    for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
    return s;
  };
  // diag 状态码 → 字典 msg_key。桌面壳是存储端本身，用桌面视角变体
  // （T-042b：手机视角的 "存储电脑离线了" 显示在存储电脑上自相矛盾；
  // 变体无 {progress}/{last_seen} 占位符——status 载荷不带这两个值，
  // 带占位符会渲染出字面 "{progress}"）。
  const STATE_KEYS = {
    ONLINE_DIRECT: "diag.online_direct",
    ONLINE_RELAY: "diag.online_relay",
    PAIRING: "diag.desktop.pairing",
    DISK_FULL: "diag.desktop.disk_full",
    INDEXING: "diag.desktop.indexing",
    STORAGE_OFFLINE: "diag.desktop.storage_offline",
  };

  let wizard = $state(null); // null=检测中, {configured, default_dir}
  let starting = $state(false);

  async function checkWizard() {
    wizard = await invoke("wizard_state");
  }

  async function stopService() {
    const yes = await confirmDialog(t("ui.stop_confirm_body"), {
      title: t("ui.stop_confirm_title"),
      kind: "warning",
    });
    if (!yes) return;
    try {
      await invoke("stop_daemon");
      message = t("ui.service_stopped");
    } catch (e) {
      message = t("ui.stop_failed", { err: String(e) });
    }
  }

  async function startDaemonNow() {
    starting = true;
    try {
      await invoke("start_daemon");
    } catch (e) {
      message = t("ui.start_failed", { err: String(e) });
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
      message = t("ui.pair_failed", { err: String(e) });
    }
  }

  async function confirmPair(accept) {
    try {
      const r = await call("pairing.confirm", { accept });
      message = accept
        ? t("ui.pair_allowed", { name: r.device })
        : t("ui.pair_denied", { name: r.device });
      await refresh();
    } catch (e) {
      message = t("ui.confirm_failed", { err: String(e) });
    }
  }

  async function revoke(nodeId, name) {
    const yes = await confirmDialog(t("ui.revoke_confirm_body", { name }), {
      title: t("ui.revoke_confirm_title"),
      kind: "warning",
    });
    if (!yes) return;
    try {
      await call("device.revoke", { node_id: nodeId });
      message = t("ui.revoked", { name });
      await refresh();
    } catch (e) {
      message = t("ui.revoke_failed", { err: String(e) });
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
      message = t("ui.open_failed", { err: String(e) });
    }
  }

  async function chooseFolder() {
    const dir = await openDialog({ directory: true, title: t("ui.change_title") });
    if (!dir) return;
    const yes = await confirmDialog(t("ui.change_body", { dir }), {
      title: t("ui.change_title"),
      kind: "warning",
    });
    if (!yes) return;
    try {
      await call("folder.set", { path: dir });
      message = t("ui.change_saved", { dir });
    } catch (e) {
      message = t("ui.save_failed", { err: String(e) });
    }
  }

  async function exportLogs() {
    try {
      const r = await call("logs.export");
      message = t("ui.logs_exported", { path: r.zip });
      try {
        await revealItemInDir(r.zip); // 在 Finder/资源管理器中直接展示
      } catch (_) {}
    } catch (e) {
      message = t("ui.export_failed", { err: String(e) });
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
      ? t("ui.offline_banner")
      : t(STATE_KEYS[status?.state] ?? status?.state)
  );
</script>

<main>
  <header>
    <h1>P-Pass</h1>
    {#if !(wizard && (!wizard.configured || !wizard.installed) && !online)}
      <span class="badge" class:ok={online} class:bad={!online}>{stateLabel}</span>
    {/if}
  </header>

  {#if message}
    <p class="message">{message}</p>
  {/if}

  {#if wizard && (!wizard.configured || !wizard.installed) && !online}
    <!-- T-042: onboarding 进行中不展示"后台服务未运行"终态——服务本来
         就要在这一步才被拉起，提前暴露只有困惑（xixi 实测反馈 1）。
         配置写了但服务没注册 = wizard 中途退出，重进继续走 wizard
         （xixi 实测反馈 3），而不是丢到"启动后台服务"裸界面。 -->
    <Wizard
      defaultDir={wizard.default_dir}
      configuredLibraryDir={wizard.configured_library_dir}
      onDone={() => { checkWizard(); refresh(); }}
    />
  {:else if !online}
    <section>
      <p>{t("ui.offline_action")}</p>
      <button class="primary" disabled={starting} onclick={startDaemonNow}>
        {starting ? t("ui.starting") : t("ui.start_service")}
      </button>
      <p class="hint">{t("ui.refresh_hint")}</p>
    </section>
  {:else}
    <section>
      <h2>状态</h2>
      <p>
        {t("ui.paired_count", { n: status.devices - status.revoked })}
        {#if status.revoked > 0}{t("ui.revoked_count", { n: status.revoked })}{/if}
        {#if pendingCount > 0}<strong>· {t("ui.pending_pairs", { n: pendingCount })}</strong>{/if}
      </p>
      {#if pendingCount > 0}
        <div class="row">
          <button class="primary" onclick={() => confirmPair(true)}>{t("ui.allow")}</button>
          <button onclick={() => confirmPair(false)}>{t("ui.deny")}</button>
        </div>
      {/if}
    </section>

    <section>
      <h2>{t("ui.add_device")}</h2>
      <div class="row">
        <button class="primary" onclick={startPairing}>{t("ui.generate_qr")}</button>
      </div>
      {#if qrDataUrl}
        <img class="qr" src={qrDataUrl} alt={t("ui.generate_qr")} />
        <details>
          <summary>{t("ui.qr_fallback")}</summary>
          <code class="qrtext">{qrText}</code>
        </details>
        <p class="hint">{t("ui.qr_hint")}</p>
      {/if}
    </section>

    <section>
      <h2>{t("ui.devices")}</h2>
      {#if devices.length === 0}
        <p class="hint">{t("ui.no_devices")}</p>
      {:else}
        <ul class="devices">
          {#each devices as d}
            <li>
              <span class:revoked={d.revoked}>
                {d.name}
                <small>{d.role}{d.revoked ? t("ui.revoked_tag") : ""}</small>
              </span>
              {#if !d.revoked}
                <button class="danger" onclick={() => revoke(d.node_id, d.name)}>{t("ui.remove")}</button>
              {/if}
            </li>
          {/each}
        </ul>
      {/if}
    </section>

    <section>
      <h2>{t("ui.settings")}</h2>
      <div class="row">
        <button class="primary" onclick={openLibrary}>{t("ui.open_library")}</button>
        <button onclick={chooseFolder}>{t("ui.change_library")}</button>
        <button onclick={exportLogs}>{t("ui.export_logs")}</button>
      </div>
      <p class="hint">{t("ui.logs_hint")}</p>
      <div class="row" style="margin-top:12px">
        <button class="danger" onclick={stopService}>{t("ui.stop_service")}</button>
      </div>
      <p class="hint">{t("ui.stop_hint")}</p>
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
