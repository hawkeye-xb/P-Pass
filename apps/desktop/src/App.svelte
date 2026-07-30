<script>
  import { invoke } from "@tauri-apps/api/core";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import QRCode from "qrcode";
  import { onMount, onDestroy } from "svelte";

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
    if (!confirm(`确定移除设备「${name}」？它将立刻失去访问权限。`)) return;
    try {
      await call("device.revoke", { node_id: nodeId });
      message = `已移除「${name}」`;
      await refresh();
    } catch (e) {
      message = `移除失败：${e}`;
    }
  }

  async function chooseFolder() {
    const dir = await openDialog({ directory: true, title: "选择照片库文件夹" });
    if (!dir) return;
    try {
      await call("folder.set", { path: dir });
      message = "库文件夹已保存，重启后台服务后生效。";
    } catch (e) {
      message = `保存失败：${e}`;
    }
  }

  async function exportLogs() {
    try {
      const r = await call("logs.export");
      message = `诊断包已导出（路径已脱敏，可放心外发）：${r.zip}`;
    } catch (e) {
      message = `导出失败：${e}`;
    }
  }

  let timer;
  onMount(() => {
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

  {#if !online}
    <section>
      <p>没有找到运行中的后台服务。请先启动 daemon（详见部署手册），本窗口每 3 秒自动重试。</p>
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
        <button onclick={chooseFolder}>更改库文件夹…</button>
        <button onclick={exportLogs}>导出诊断包</button>
      </div>
      <p class="hint">诊断包会自动抹去用户名等隐私路径，可安全提供给支持人员。</p>
    </section>
  {/if}
</main>

<style>
  :global(body) {
    margin: 0;
    font-family: -apple-system, "PingFang SC", "Segoe UI", sans-serif;
    background: #f4f6f9;
    color: #1c2733;
  }
  main {
    max-width: 640px;
    margin: 0 auto;
    padding: 20px;
  }
  header {
    display: flex;
    align-items: center;
    gap: 12px;
  }
  h1 {
    font-size: 22px;
    margin: 0;
  }
  h2 {
    font-size: 15px;
    margin: 0 0 8px;
  }
  section {
    background: #fff;
    border-radius: 10px;
    padding: 14px 16px;
    margin-top: 14px;
    box-shadow: 0 1px 3px rgba(16, 33, 60, 0.08);
  }
  .badge {
    font-size: 12px;
    padding: 3px 10px;
    border-radius: 999px;
    background: #d7dde5;
  }
  .badge.ok {
    background: #d9f2e2;
    color: #14683a;
  }
  .badge.bad {
    background: #fbe1e1;
    color: #8f1d1d;
  }
  .row {
    display: flex;
    gap: 10px;
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
  button.danger {
    color: #a11212;
    border-color: #e2b3b3;
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
  .devices {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .devices li {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 8px 0;
    border-bottom: 1px solid #eef1f5;
  }
  .devices li:last-child {
    border-bottom: none;
  }
  .devices small {
    color: #6b7684;
    margin-left: 8px;
  }
  .revoked {
    color: #9aa4b0;
    text-decoration: line-through;
  }
  .hint {
    color: #6b7684;
    font-size: 12px;
    margin: 8px 0 0;
  }
  .message {
    background: #fff8e1;
    border: 1px solid #eadfa3;
    border-radius: 8px;
    padding: 8px 12px;
    font-size: 13px;
  }
</style>
