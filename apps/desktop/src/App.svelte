<script>
  import { invoke } from "@tauri-apps/api/core";
  import { getVersion } from "@tauri-apps/api/app";
  import { listen } from "@tauri-apps/api/event";
  import { open as openDialog, confirm as confirmDialog } from "@tauri-apps/plugin-dialog";
  import { check as checkUpdate } from "@tauri-apps/plugin-updater";
  import { revealItemInDir, openUrl } from "@tauri-apps/plugin-opener";
  import QRCode from "qrcode";
  import { onMount, onDestroy } from "svelte";
  import Wizard from "./Wizard.svelte";
  import PhotoThumb from "./lib/PhotoThumb.svelte";
  // T-091: 人性化时间 + 哨兵判定纯函数（时间戳单位见模块头注释：unix 毫秒）
  import { humanTime, needsAttention, daysSince, relativeTime } from "./lib/humanTime.js";
  // T-092: connection 四态 → 文案/点色；字节 → 人读容量（纯函数，
  // apps/desktop/scripts/check-wire-fns.mjs 断言）
  // PRES-01: presence 三档 → 文案/点色（connection 路径事实优先展示）
  import { presenceText } from "./lib/connection.js";
  import { formatBytes, diskUsedPercent } from "./lib/formatBytes.js";
  // T-072: 状态/错误文案的唯一来源是 diag 字典（crates/diag 注册表 +
  // assets/i18n/*.json，Rust 测试保证双语文案齐全）。直接从仓库根引用，
  // 零副本零漂移；按系统语言选语言表（UI 单语显示的既定决策）。
  // T-081: 布局 v1 新增的导航/页面文案按设计稿原文暂写死在组件里
  //（assets/i18n 不在本卡范围），后续卡收编进字典。
  import enDict from "../../../assets/i18n/en.json";
  import zhDict from "../../../assets/i18n/zh.json";

  const dict = (navigator.language || "zh").toLowerCase().startsWith("zh") ? zhDict : enDict;
  const t = (key, vars = {}) => {
    let s = dict[key] ?? key;
    for (const [k, v] of Object.entries(vars)) s = s.replaceAll(`{${k}}`, String(v));
    return s;
  };

  // ---- T-081 布局 v1：侧边栏四页（总览 / 家人与设备 / 活动记录 / 设置，
  // 照片库并入设置）。hash 同步只为可验证/可深链，不引入路由依赖。
  // DESK-03: 新增「照片」页（照片墙）——侧边栏第五项，文案走 i18n。
  const NAV = [
    { id: "overview", label: "总览" },
    { id: "photos", label: t("ui.nav_photos") },
    { id: "devices", label: "家人与设备" },
    { id: "log", label: "活动记录" },
    { id: "settings", label: "设置" },
  ];
  const pageFromHash = () => {
    const m = (location.hash || "").match(/^#\/(overview|photos|devices|log|settings)$/);
    return m ? m[1] : "overview";
  };
  let page = $state(pageFromHash());
  function go(id) {
    page = id;
    location.hash = `#/${id}`;
  }
  function onHashChange() {
    page = pageFromHash();
  }

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
      flashMessage(t("ui.service_stopped"));
    } catch (e) {
      flashMessage(t("ui.stop_failed", { err: String(e) }));
    }
  }

  async function startDaemonNow() {
    starting = true;
    try {
      await invoke("start_daemon");
    } catch (e) {
      flashMessage(t("ui.start_failed", { err: String(e) }));
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
  // UX-08: 待确认配对请求全量列表（pairing.pending）——一屏一行，逐行
  // 允许/拒绝；处理完该行消失，全清后模态关闭，无残留状态。
  let pendingList = $state([]);
  // UX-08: 提示条 5s 自动消失（右侧 × 手动关闭）的定时器句柄。
  let messageTimer = null;
  // T4 (H-10b): 配对状态机——二维码是弹窗模块，不是常驻卡片。有人扫码
  // （pending 出现）→ 关二维码弹窗 → 切「允许/拒绝」模态 → 处理完关闭，
  // 状态消失（不再一直占空间）。审计记录在 T5。
  let showPairModal = $state(false);
  let showConfirmModal = $state(false);
  // T-091: node_id -> {last_backup_at, asset_count}（device.watermarks，毫秒）
  let watermarks = $state({});
  // T-092: activity.list 批次（{node_id,name,at,asset_count}，at=unix 毫秒，
  // name 可能 null）——活动记录页数据源
  let activity = $state([]);
  // T5: 审计事件流（{ts, action, actor, detail}）——配对请求/允许/拒绝、
  // 备份会话、吊销，活动页的主数据源。
  let auditEvents = $state([]);
  // T1 (H-10b): 界面显示版本号——报问题/排查时先知道装的是什么版本。
  let version = $state("");
  getVersion().then((v) => (version = v)).catch(() => {});
  // DESK-02①: 更新通道由构建推导——daemon status.version 带完整 tag
  // （release 构建 = PPF_BUILD_VERSION 注入 "v0.3.2-test.2"），含 `-test.`
  // → test 通道，否则 stable。零 UI、零持久化（旧 REL-02 显式切换已删）。
  // 壳版本（tauri.conf.json）无 tag 后缀，daemon 不可达时回退壳版本（stable）。
  const displayVersion = $derived(status?.version || version);
  const updateChannel = $derived(
    displayVersion.includes("-test.") ? "test" : "stable"
  );
  const isTestBuild = $derived(displayVersion.includes("-test."));
  // DEV-01b: 重装识别/「替换旧的」入口先隐藏（用户拍板 2026-08-12）——
  // 现阶段统一走「重新扫码 = 全新授权」，不给用户多一个要理解的概念。
  // 编译期 flag 默认关；打开 = DEV-01 行为原样回来（反证路径）。
  // 底层不拆：pair.request 的 device_hint 照发照存（数据继续积累），
  // 未来打开入口即用。关闭时对话框与 DEV-01 之前完全一致。
  const MERGE_ENTRY_ENABLED = false;
  // 人性化时间的「现在」——随 3s 轮询一起刷新，行文案不会停在旧相对时间
  let nowMs = $state(Date.now());

  async function call(method, params = {}) {
    return await invoke("daemon_call", { method, params });
  }

  // UX-08: 提示条——5s 自动消失 + 右侧 × 手动关闭，两者都要。
  // 反证：把自动消失定时器去掉 → 验收 2 必挂（提示条常驻）。
  function flashMessage(msg) {
    message = msg;
    clearTimeout(messageTimer);
    messageTimer = setTimeout(() => (message = ""), 5000);
  }

  async function refresh() {
    try {
      status = await call("status");
      online = true;
      pendingCount = status.pending_pairs ?? 0;
      // UX-08: pending 全量列表（pairing.pending，只读）——列表化显示
      // 的基础；拿不到时回退数量（老 daemon 升级过渡）。
      // DEV-01: 每项可能是 {name, hint_match}（新 daemon）或纯字符串
      // （老 daemon）——统一 normalize 成对象。
      try {
        const p = await call("pairing.pending", {});
        pendingList = (p.pending ?? []).map((x) =>
          typeof x === "string" ? { name: x, hint_match: null } : x
        );
      } catch (_) {
        pendingList = [];
      }
      // T4: pending 从无到有 = 有人扫了码——关二维码弹窗、打开允许/拒绝。
      // UX-08: 一屏列全部 pending，逐行处理；全清后关闭，无残留。
      if (pendingList.length > 0 && showPairModal) {
        showPairModal = false;
        showConfirmModal = true;
      } else if (pendingList.length === 0 && showConfirmModal) {
        // 已处理完（confirmPair 清空 pending）——状态消失，不残留。
        showConfirmModal = false;
      }
      const d = await call("devices.list");
      devices = d.devices ?? [];
      nowMs = Date.now();
      // T-091: 水位数据单独容错——拿不到不拖垮整页（保留上次值）
      try {
        const w = await call("device.watermarks");
        watermarks = Object.fromEntries((w.watermarks ?? []).map((x) => [x.node_id, x]));
      } catch (_) {}
      // T-092: 活动记录同样单独容错——倒序（新的在上）由 UI 兜底保证
      try {
        const a = await call("activity.list", { limit: 100 });
        activity = (a.batches ?? []).slice().sort((x, y) => (y.at ?? 0) - (x.at ?? 0));
      } catch (_) {}
      // T5: 审计事件流（配对/会话/吊销）——活动页主数据源。
      try {
        const au = await call("audit.list", { limit: 200 });
        auditEvents = (au.events ?? []).slice().sort((x, y) => (y.ts ?? 0) - (x.ts ?? 0));
      } catch (_) {}
    } catch (e) {
      online = false;
      status = null;
    }
  }

  // T5: 审计事件 → 人话行文案（未知 action 兜底显示原始类型，绝不吞）。
  function auditLine(e) {
    const d = e.detail ?? "";
    const who = devices.find((x) => x.node_id === e.actor)?.name ?? null;
    switch (e.action) {
      case "pair.requested":
        return `${(who ?? d) || "未知设备"} 请求加入`;
      case "pair.accepted":
        return `${who ?? d} 已加入`;
      case "pair.denied":
        return `${who ?? d} 加入被拒绝`;
      case "backup.started":
        return `${who ?? "设备"} 开始备份`;
      case "backup.finished":
        return `${who ?? "设备"} 备份完成（${d}）`;
      case "device.revoked":
        return `已移除设备 ${(e.actor ?? "").slice(0, 8)}…`;
      case "device.unpaired":
        return `${who ?? "设备"} 主动断开连接`;
      case "device.connected":
        // PRES-01: hello 心跳进活动流——「小红 连接了」（10 分钟去重，
        // 防锁屏重连刷屏）。
        return `${who ?? d} 连接了`;
      case "backup.commit":
        return `备份提交（${d}）`;
      case "external.delete":
        return `外部删除（${d}）`;
      default:
        return `${e.action} ${d}`.trim();
    }
  }

  // PRES-01: sub 槽接 devices.list[].presence 三档（online 优先展示连接
  // 路径事实：已直连/经中继；心跳新鲜无活连接 → 「在线」；recent →
  // 「x 分钟前在线」；offline → 「离线，最后在线 <时间>」/「等待下次备份
  // 上报」）。哨兵红优先级高于 presence——一台设备两个真相时先说要紧的。
  function deviceRow(d, now) {
    const wm = watermarks[d.node_id];
    const lastBackupAt = wm?.last_backup_at ?? null;
    const backupTime = humanTime(lastBackupAt, now);
    const alert = needsAttention(lastBackupAt, now);
    if (alert) {
      return {
        alert: true,
        dot: "act",
        sub: `${daysSince(lastBackupAt, now)} 天没备份了——去那台手机上打开一次 App 就会自动补上`,
        right: "需要看看",
      };
    }
    const pres = presenceText(
      d.presence,
      d.connection,
      relativeTime(d.last_seen, now),
      humanTime(d.last_seen, now)
    );
    return {
      alert: false,
      dot: pres.dot,
      sub: pres.sub,
      right: backupTime ? `最近备份 ${backupTime} · ${wm.asset_count} 张` : "还没备份过",
    };
  }

  async function startPairing() {
    message = "";
    showPairModal = true; // T4: 二维码是弹窗模块，不是常驻卡片
    try {
      const r = await call("pairing.start");
      qrText = r.qr;
      // T4: 弹窗内大尺寸——显示 360px，生成 2x（720）保高分屏清晰；
      // 配对码已瘦身（H-10b T3），低纠错 L 在内容较长时更好扫。
      qrDataUrl = await QRCode.toDataURL(r.qr, {
        width: 720,
        margin: 2,
        errorCorrectionLevel: "L",
      });
    } catch (e) {
      flashMessage(t("ui.pair_failed", { err: String(e) }));
    }
  }

  function closePairModal() {
    showPairModal = false;
    // 关弹窗即弃当前码（token 仍在 TTL 内有效，但下次打开重新生成更干净）。
    qrDataUrl = "";
    qrText = "";
  }

  async function confirmPair(accept, name, mergeNodeId) {
    try {
      // UX-08: 逐行处理——pairing.confirm 带 device_name 精确确认该台；
      // 不带则默认队首（老调用方兼容，语义不动）。
      // DEV-01: merge_node_id 存在 = 用户选「替换旧的」——daemon 迁移
      // 旧设备资产/水位后删除旧行；不传 = 作为新设备（与现状一致）。
      const r = await call("pairing.confirm", {
        accept,
        device_name: name,
        merge_node_id: mergeNodeId ?? null,
      });
      flashMessage(
        accept ? t("ui.pair_allowed", { name: r.device }) : t("ui.pair_denied", { name: r.device })
      );
      // T4: 处理完由下一轮 refresh 关模态（pending 清 0）——状态消失不残留。
      await refresh();
    } catch (e) {
      flashMessage(t("ui.confirm_failed", { err: String(e) }));
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
      flashMessage(t("ui.revoked", { name }));
      await refresh();
    } catch (e) {
      flashMessage(t("ui.revoke_failed", { err: String(e) }));
    }
  }

  // ── NAME-01: 设备改名（decisions ② ID 与显示名分离）──────────────
  // 点设备名 → 变输入框；回车/失焦保存（空名/未改动不提交）；Esc 取消。
  let renameTarget = $state(null); // { nodeId, name }
  let renameValue = $state("");

  function startRename(d) {
    renameTarget = { nodeId: d.node_id, name: d.name };
    renameValue = d.name;
  }

  async function commitRename() {
    const target = renameTarget;
    if (!target) return;
    const trimmed = renameValue.trim();
    renameTarget = null;
    if (!trimmed || trimmed === target.name) return; // 空名/未改动 = 不提交
    try {
      const r = await call("device.rename", {
        node_id: target.nodeId,
        name: trimmed,
      });
      flashMessage(t("ui.rename_saved", { name: r.name ?? trimmed }));
      await refresh();
    } catch (e) {
      flashMessage(t("ui.rename_failed", { err: String(e) }));
    }
  }

  async function openLibrary() {
    try {
      const s = await call("status");
      const dir = s.library_dir;
      if (!dir) throw new Error(t("ui.library_dir_unknown"));
      // originals/ 是照片所在；库刚建还没照片时打开库根目录。
      try {
        await revealItemInDir(`${dir}/originals`);
      } catch (_) {
        await revealItemInDir(dir);
      }
    } catch (e) {
      flashMessage(t("ui.open_failed", { err: String(e) }));
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
      flashMessage(t("ui.change_saved", { dir }));
    } catch (e) {
      flashMessage(t("ui.save_failed", { err: String(e) }));
    }
  }

  async function exportLogs() {
    try {
      const r = await call("logs.export");
      flashMessage(t("ui.logs_exported", { path: r.zip }));
      try {
        await revealItemInDir(r.zip); // 在 Finder/资源管理器中直接展示
      } catch (_) {}
    } catch (e) {
      flashMessage(t("ui.export_failed", { err: String(e) }));
    }
  }

  let timer;
  let unlisten;
  onMount(() => {
    checkWizard();
    // DESK-02①: 更新检查放首次 status 落地后——updateChannel 由
    // status.version（完整 tag）推导，避免启动竞态按壳版本误判 stable。
    refresh().then(() => checkForUpdate(false));
    // IPC-02: 事件驱动为主——daemon 事件（扫码/配对落定/备份落地/设备
    // 变化）即时刷新；轮询降级为 60s 兜底对账（防漏事件，不再是主通道）。
    timer = setInterval(refresh, 60000); // 契约: 兜底对账 60s
    // 订阅线程在 src-tauri setup 启动（start_event_stream），事件经
    // `daemon-event` 转发——这里只负责收。
    listen("daemon-event", onDaemonEvent).then((f) => (unlisten = f));
    window.addEventListener("hashchange", onHashChange);
  });
  onDestroy(() => {
    clearInterval(timer);
    unlisten?.();
    window.removeEventListener("hashchange", onHashChange);
  });

  // IPC-02: daemon 事件 → 即时刷新。事件是加速器，丢了也有 60s 兜底
  // 对账——全量 refresh() 简单可靠（本地 IPC 快、事件频率低）。
  function onDaemonEvent(ev) {
    const name = ev?.payload?.event;
    if (!name) return;
    // 事件帧 {event, data}——data 是占位/增量提示，具体状态一律全量拉。
    refresh();
  }

  // UPD-01: 启动时检查一次更新（tauri-plugin-updater；manifest 在
  // tauri.conf.json endpoints，release 资产直链——draft/无 release 时
  // 404 = 无更新，静默）。失败静默，绝不打扰用户。
  // UPD-01 返工：check 阶段任何错误（404=无正式 release、网络不可达）
  // 一律静默返回——tauri 的 check() 只有 204 才当「无更新」，404 会
  // reject，原实现把 404 也显示成「更新失败」，无 release 时每次启动
  // 都弹错。只有用户点了「下载安装」后的下载/安装失败才上文案。
  // T-081: 设置页「检查更新」手动入口复用同一函数（manual=true 时
  // 「已是最新」也给一句反馈，不再沉默）。
  // REL-02: test 通道的 manifest 源——Cloudflare Worker 代理
  // （infra/workers/update；GitHub API 未认证限流 60/h/IP，客户端不
  // 直连；解析最新 prerelease 在 Worker 端，命中 300s 缓存）。
  const WORKER_TEST_URL = "https://update.p-pass.hawkeye-xb.com/manifest?channel=test";

  // SemVer 三段比较（与 Android UpdateChecker.isNewer 同语义）。
  // DESK-02①: 同核心预发布按数字段比较（0.3.2-test.2 > 0.3.2-test.1）——
  // test 通道连续 tag 自动升级的判据；正式 > 预发布（同核心）。
  function isNewerVersion(candidate, current) {
    const parse = (s) => {
      const parts = String(s).split("-");
      const nums = parts[0].split(".").map((x) => parseInt(x, 10) || 0);
      return { nums, pre: parts[1] ?? null };
    };
    const c = parse(candidate);
    const cur = parse(current);
    for (let i = 0; i < 3; i++) {
      const d = (c.nums[i] ?? 0) - (cur.nums[i] ?? 0);
      if (d !== 0) return d > 0;
    }
    if (c.pre === null && cur.pre !== null) return true;
    if (c.pre !== null && cur.pre === null) return false;
    if (c.pre !== null && cur.pre !== null) {
      const a = parseInt(c.pre.replace(/\D/g, "") || "0", 10);
      const b = parseInt(cur.pre.replace(/\D/g, "") || "0", 10);
      return a > b;
    }
    return false;
  }

  // REL-02: test 通道检查——壳内 fetch Worker manifest，弹窗后打开
  // 下载页。安装路径说明：tauri updater 的 endpoint 构建期写死、Update
  // 无公开构造器，运行时无法指向任意 manifest URL（2.10.1 源码确认）；
  // 且当前 release manifest 只含 android-arm64（桌面壳待建）——test
  // 通道「检查到更新 + 一键打开下载页」是当前平台约束下的诚实形态。
  async function checkTestChannel(manual) {
    try {
      const resp = await fetch(WORKER_TEST_URL);
      if (!resp.ok) {
        if (manual) flashMessage("没有发现新版本。");
        return;
      }
      const m = await resp.json();
      if (!m?.version || !isNewerVersion(m.version, version)) {
        if (manual) flashMessage("没有发现新版本。");
        return;
      }
      const ok = await confirmDialog(t("ui.update_available", { version: m.version }), {
        title: "P-Pass",
      });
      if (!ok) return;
      // 优先资产直链（manifest 里 darwin 条目），没有则落到 release 页。
      const entry =
        m.platforms?.["darwin-aarch64"] ??
        m.platforms?.["macos-arm64"] ??
        m.platforms?.["macos-x64"];
      const url =
        entry?.url || `https://github.com/hawkeye-xb/P-Pass/releases/tag/v${m.version}`;
      await openUrl(url);
    } catch (e) {
      console.warn("[updater] test channel check failed (silent):", e);
      if (manual) flashMessage("没有发现新版本。");
    }
  }

  async function checkForUpdate(manual = true) {
    // REL-02: test 通道走壳内检查（Worker 源）；stable 保持原 tauri
    // updater 路径（语义不动）。
    if (updateChannel === "test") {
      await checkTestChannel(manual);
      return;
    }
    let update;
    try {
      update = await checkUpdate();
    } catch (e) {
      console.warn("[updater] check failed (silent — 404/draft/network = no update):", e);
      if (manual) flashMessage("没有发现新版本。");
      return;
    }
    if (!update) {
      if (manual) flashMessage("没有发现新版本。");
      return;
    }
    const ok = await confirmDialog(t("ui.update_available", { version: update.version }), {
      title: "P-Pass",
    });
    if (!ok) return;
    try {
      await update.downloadAndInstall();
      flashMessage(t("ui.update_installed"));
    } catch (e) {
      flashMessage(t("ui.update_failed", { err: String(e) }));
    }
  }

  // UX-04: 徽章 = 服务态二元（运行中 / 后台服务未运行），不再展示连接
  // 状态（直连/中继是连接路径事实，不属于服务态；现状 ONLINE_DIRECT 是
  // 状态机默认值，当作徽章文案是假话）。T-081: 徽章落位侧栏底部胶囊，
  // 只说服务状态；连接状态归属每台设备行（daemon 尚未暴露 per-device
  // 连接事实，行内先留结构：状态点 + 右侧槽位）。
  const pairedCount = $derived(status ? status.devices - status.revoked : 0);
  // T-092: 磁盘水位（status.disk_free_bytes/disk_total_bytes 可能 null——
  // 拿不到时三个值都是 null，设置页整行隐藏，绝不渲染 undefined/NaN）
  const diskFree = $derived(formatBytes(status?.disk_free_bytes ?? null));
  const diskTotal = $derived(formatBytes(status?.disk_total_bytes ?? null));
  const diskPct = $derived(
    diskUsedPercent(status?.disk_free_bytes ?? null, status?.disk_total_bytes ?? null)
  );
  // T-092: 总览副标题「照片库 M 张」——photo_count 缺失时整段隐藏
  const photoCount = $derived(
    typeof status?.photo_count === "number" && Number.isFinite(status.photo_count)
      ? status.photo_count
      : null
  );

  // ---- DESK-03: 照片墙（与手机同一数据源 query.timeline / thumb） ----
  // 缩略图墙分页懒加载；点开 = 原图内存展示（asset.original，不落盘）+
  // 「在 Finder 中显示」（asset.path → originals 原文件）。被外删的照片
  // 由 SYNC-01 对账从墙上自然消失（两卡独立可验）。
  const photoSources = $derived(
    typeof status?.photo_sources === "number" && Number.isFinite(status.photo_sources)
      ? status.photo_sources
      : null
  );
  const PHOTOS_PAGE_SIZE = 60;
  let photos = $state([]); // AssetMeta[]，timeline 顺序（新→旧）
  let photosNext = $state(null); // 分页游标
  let photosLoading = $state(false);
  let photosLoaded = $state(false); // 首次加载完成（区分空库与未加载）
  let sentinelEl = $state(null); // 墙底哨兵 → 触发下一页
  let photoViewer = $state(null); // {hash, taken_at, media_type} 大图目标
  let viewerSrc = $state(null); // 大图 data URL（原图或 1024 降级）
  let viewerPath = $state(null); // 原文件绝对路径（Finder 揭示）

  async function loadPhotosPage() {
    if (photosLoading || !photosNext) return;
    photosLoading = true;
    try {
      const r = await call("timeline.page", { cursor: photosNext, limit: PHOTOS_PAGE_SIZE });
      photos = photos.concat(r.items ?? []);
      photosNext = r.next ?? null;
    } catch (_) {
      photosNext = null; // 下一页拿不到就停，不循环报错
    } finally {
      photosLoading = false;
      photosLoaded = true;
    }
  }

  // 进照片页拉第一页；哨兵可见 → 拉下一页（滚动流畅的关键：按需加载）。
  $effect(() => {
    if (page !== "photos") return;
    if (!photosLoaded && !photosLoading) {
      photosLoading = true;
      call("timeline.page", { cursor: null, limit: PHOTOS_PAGE_SIZE })
        .then((r) => {
          photos = r.items ?? [];
          photosNext = r.next ?? null;
        })
        .catch(() => (photosNext = null))
        .finally(() => {
          photosLoading = false;
          photosLoaded = true;
        });
    }
    if (sentinelEl) {
      const io = new IntersectionObserver(
        (entries) => {
          if (entries[0].isIntersecting) loadPhotosPage();
        },
        { rootMargin: "400px" }
      );
      io.observe(sentinelEl);
      return () => io.disconnect();
    }
  });

  // taken_at 是秒（proto AssetMeta）——按「今天 / 本月 / 更早」分组。
  function photoGroupKey(tsSec) {
    const d = new Date(tsSec * 1000);
    const now = new Date();
    if (d.toDateString() === now.toDateString()) return "today";
    if (d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth()) return "month";
    return "earlier";
  }
  const photoGroups = $derived.by(() => {
    const groups = [
      { key: "today", label: t("ui.photos_today"), items: [] },
      { key: "month", label: t("ui.photos_month"), items: [] },
      { key: "earlier", label: t("ui.photos_earlier"), items: [] },
    ];
    for (const item of photos) {
      groups.find((g) => g.key === photoGroupKey(item.taken_at)).items.push(item);
    }
    return groups.filter((g) => g.items.length > 0);
  });

  // 大图：原图内存展示（asset.original）；>12MiB/视频/失败 → 1024 缩略图
  // 降级。关闭即清引用——「不长期落盘」由不写任何临时文件天然满足。
  $effect(() => {
    const v = photoViewer;
    viewerSrc = null;
    viewerPath = null;
    if (!v) return;
    let cancelled = false;
    (async () => {
      try {
        const o = await call("asset.original", { hash: v.hash });
        if (!cancelled) viewerSrc = `data:image/jpeg;base64,${o.data_base64}`;
      } catch (_) {
        try {
          const t = await call("thumb.get", { hash: v.hash, size: 1024 });
          if (!cancelled) viewerSrc = `data:image/jpeg;base64,${t.jpeg_base64}`;
        } catch (_) {}
      }
      try {
        const p = await call("asset.path", { hash: v.hash });
        if (!cancelled) viewerPath = p.path;
      } catch (_) {}
    })();
    return () => {
      cancelled = true;
    };
  });

  async function revealPhotoInFinder() {
    if (!viewerPath) return;
    try {
      await revealItemInDir(viewerPath);
    } catch (e) {
      flashMessage(`无法在 Finder 中显示：${e}`);
    }
  }
</script>

{#if wizard && (!wizard.configured || !wizard.installed) && !online}
  <!-- T-042: onboarding 进行中不展示"后台服务未运行"终态——服务本来
       就要在这一步才被拉起，提前暴露只有困惑（xixi 实测反馈 1）。
       配置写了但服务没注册 = wizard 中途退出，重进继续走 wizard
       （xixi 实测反馈 3），而不是丢到"启动后台服务"裸界面。 -->
  <main class="wizard-shell">
    <header>
      <h1>P-Pass</h1>
    </header>
    {#if message}
      <p class="message">
        {message}
        <!-- UX-08: 提示条右侧 × 手动关闭（5s 自动消失之外的第二条路） -->
        <button class="message-close" aria-label="关闭提示" onclick={() => (message = "")}>×</button>
      </p>
    {/if}
    <Wizard
      defaultDir={wizard.default_dir}
      configuredLibraryDir={wizard.configured_library_dir}
      onDone={() => { checkWizard(); refresh(); }}
    />
  </main>
{:else}
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">P-Pass</div>
      <nav>
        {#each NAV as n}
          <button
            class="nav-item"
            class:active={page === n.id}
            aria-current={page === n.id ? "page" : undefined}
            onclick={() => go(n.id)}
          >{n.label}</button>
        {/each}
      </nav>
      <!-- 顶部徽章只表示服务状态（UX-04），落位侧栏底部胶囊。 -->
      <div class="service-pill" class:ok={online} class:bad={!online}>
        <span class="dot"></span>
        <span>{online ? "后台服务运行中" : t("ui.offline_banner")}</span>
      </div>
    </aside>

    <main class="content" data-page={page}>
      {#if message}
        <p class="message">
          {message}
          <!-- UX-08: 提示条右侧 × 手动关闭（5s 自动消失之外的第二条路） -->
          <button class="message-close" aria-label="关闭提示" onclick={() => (message = "")}>×</button>
        </p>
      {/if}

      {#if page === "overview"}
        <section class="page" data-testid="page-overview">
          <div class="lede">
            <h2 class="headline">全家的照片，安全地住在这台电脑上。</h2>
            <!-- T-092: 副标题接 status.photo_count——「已配对设备 N 台 · 照片库 M 张」；
                 photo_count 缺失时该段整体隐藏 -->
            <p class="sub">
              {t("ui.paired_count", { n: pairedCount })}{#if photoCount !== null}{` · 照片库 ${photoCount} 张`}{/if}
              {#if status && status.revoked > 0}{t("ui.revoked_count", { n: status.revoked })}{/if}
            </p>
          </div>

          {#if !online}
            <div class="card offline-card">
              <p>{t("ui.offline_action")}</p>
              <button class="primary" disabled={starting} onclick={startDaemonNow}>
                {starting ? t("ui.starting") : t("ui.start_service")}
              </button>
              <p class="hint">{t("ui.refresh_hint")}</p>
            </div>
          {:else}
            {#if pendingCount > 0 && !showConfirmModal}
              <div class="pending-card">
                <div class="pending-text">
                  <strong>{t("diag.desktop.pairing")}</strong>
                  <span>{t("ui.pending_pairs", { n: pendingCount })}</span>
                </div>
                <div class="row">
                  <button onclick={() => confirmPair(false)}>{t("ui.deny")}</button>
                  <button class="primary" onclick={() => confirmPair(true)}>{t("ui.allow")}</button>
                </div>
              </div>
            {/if}

            <div class="cols">
              <div class="card grow">
                <h3>全家备份水位</h3>
                {#if devices.filter((d) => !d.revoked).length === 0}
                  <p class="hint">{t("ui.no_devices")}</p>
                {:else}
                  <ul class="device-rows">
                    {#each devices.filter((d) => !d.revoked) as d}
                      {@const row = deviceRow(d, nowMs)}
                      <li>
                        <!-- T-091: 右侧接 device.watermarks 真数据（设计稿总览
                             水位卡为单行结构）。T-092: 行点变四色——哨兵 act >
                             连接态（direct=safe / relay=wait / offline·unknown=idle）。 -->
                        <span class="statusdot {row.dot}"></span>
                        <span class="dev-name">{d.name}</span>
                        <span class="dev-right" class:act={row.alert}>{row.right}</span>
                      </li>
                    {/each}
                  </ul>
                {/if}
                <p class="hint">只要这台电脑开着、手机插电连 Wi-Fi，备份就在发生；任何一边不对劲，另一边 3 天内亮红。</p>
              </div>

              <!-- T-082: 设计稿——卡内容水平居中（标题左上），二维码 148×148
                   白底圆角带边框，hint 与「无法扫码」折叠器跟随居中。 -->
              <!-- T4 (H-10b): 二维码不再是常驻卡片——点按钮弹窗出码，配对完
                   状态消失；扫码后的允许/拒绝也走模态。 -->
              <div class="card qr-card">
                <h3>{t("ui.add_device")}</h3>
                <p class="hint qr-hint">点下面的按钮弹出配对码，用家人手机上的 P-Pass 扫一下；码 10 分钟内有效，可随时刷新。</p>
                <button class="primary" onclick={startPairing}>{t("ui.generate_qr")}</button>
              </div>
            </div>
          {/if}
        </section>
      {:else if page === "devices"}
        <section class="page" data-testid="page-devices">
          <div class="lede">
            <h2 class="headline">家人与设备</h2>
            <p class="sub">{t("ui.paired_count", { n: pairedCount })}</p>
          </div>
          <div class="card">
            {#if devices.length === 0}
              <p class="hint">{t("ui.no_devices")}</p>
            {:else}
              <!-- T-082: 设计稿两行结构——首行设备名加粗，次行「机型 · 连接状态」
                   槽位；daemon 尚未暴露机型/连接事实，数据未接前显示中性占位，
                   不捏造「已直连」。不再渲染原始 role 字串。 -->
              {@const activeDevices = devices.filter((d) => !d.revoked)}
              {@const removedDevices = devices.filter((d) => d.revoked)}
              {#if activeDevices.length === 0}
                <p class="hint">{t("ui.no_devices")}</p>
              {:else}
                <ul class="device-rows roomy">
                  {#each activeDevices as d}
                    {@const row = deviceRow(d, nowMs)}
                    <li>
                      <!-- T-091: 右侧「最近备份 <人性化时间> · N 张」；哨兵行
                           ACT 色 + 「需要看看」+ 设计稿原文话术。
                           T-092: 次行接 connection 真数据（已直连 / 经中继连接
                           ——内容加密，中继无法读取 / 离线，最后在线 <人性化时间>），
                           unknown 保持 T-082 中性占位；哨兵红 > 连接态。机型
                           daemon 仍未暴露，不捏造。 -->
                      <span class="statusdot {row.dot}"></span>
                      <span class="dev-main">
                        {#if renameTarget?.nodeId === d.node_id}
                          <!-- NAME-01: 改名输入框——回车保存 / Esc 取消 /
                               失焦保存（空名与未改动不提交）。 -->
                          <input
                            class="dev-rename"
                            value={renameValue}
                            oninput={(e) => (renameValue = e.currentTarget.value)}
                            onkeydown={(e) => {
                              if (e.key === "Enter") commitRename();
                              else if (e.key === "Escape") renameTarget = null;
                            }}
                            onblur={commitRename}
                            autofocus
                          />
                        {:else}
                          <button
                            class="dev-name dev-name-btn"
                            title={t("ui.rename")}
                            onclick={() => startRename(d)}
                          >{d.name}</button>
                        {/if}
                        <span class="dev-sub">{row.sub}</span>
                      </span>
                      <span class="dev-right" class:act={row.alert}>{row.right}</span>
                      <button class="danger" onclick={() => revoke(d.node_id, d.name)}>{t("ui.remove")}</button>
                    </li>
                  {/each}
                </ul>
              {/if}
              {#if removedDevices.length > 0}
                <!-- T-082: 已移除设备折叠为展开器，展开后用 ink-40 弱化，
                     不再划线平铺。 -->
                <details class="removed-fold">
                  <summary>已移除设备 {removedDevices.length} 台</summary>
                  <ul class="device-rows roomy">
                    {#each removedDevices as d}
                      <li>
                        <span class="statusdot idle"></span>
                        <span class="dev-name removed-name">{d.name}</span>
                      </li>
                    {/each}
                  </ul>
                </details>
              {/if}
            {/if}
          </div>
          <p class="hint">移除设备会让它立刻失去访问权限——危险操作只放在电脑上。</p>
        </section>
      {:else if page === "photos"}
        <!-- DESK-03: 照片墙——与手机时间线同一数据源（query.timeline +
             thumb.get），本机直连 daemon 拉取；分组 今天/本月/更早；
             点开 = 原图内存查看（不落盘）+「在 Finder 中显示」原文件。 -->
        <section class="page" data-testid="page-photos">
          <div class="lede">
            <h2 class="headline">{t("ui.nav_photos")}</h2>
            <p class="sub">
              {t("ui.photos_count", {
                n: photoCount !== null ? photoCount : 0,
                m: photoSources !== null ? photoSources : 0,
              })}
            </p>
          </div>
          <div class="card photo-wall">
            {#if photosLoaded && photos.length === 0}
              <p class="hint">{t("ui.photos_empty")}</p>
            {:else if !photosLoaded}
              <p class="hint">正在加载照片…</p>
            {:else}
              {#each photoGroups as g (g.key)}
                <h4 class="photo-group">{g.label}</h4>
                <div class="photo-grid">
                  {#each g.items as item (item.hash)}
                    <button
                      class="photo-cell"
                      onclick={() => (photoViewer = item)}
                      aria-label="查看大图"
                    >
                      <PhotoThumb hash={item.hash} />
                      {#if item.media_type === "video"}
                        <span class="video-badge">▶</span>
                      {/if}
                    </button>
                  {/each}
                </div>
              {/each}
              {#if photosNext}
                <div class="photo-sentinel" bind:this={sentinelEl}>
                  {photosLoading ? "加载中…" : ""}
                </div>
              {/if}
            {/if}
          </div>
          <p class="hint">照片都存在这台电脑上；在 Finder 里删掉的照片会从墙上消失。</p>
        </section>
      {:else if page === "log"}
        <section class="page" data-testid="page-log">
          <div class="lede">
            <h2 class="headline">活动记录</h2>
            <p class="sub">谁备份了什么，一目了然——不用去 Finder 里对账。</p>
          </div>
          <!-- T5: 活动记录页展示审计事件流——配对请求/允许/拒绝、备份会话
               （开始/结束+数量）、设备吊销/断开，全部带时间倒序。 -->
          <div class="card">
            {#if auditEvents.length === 0}
              <p class="hint">这里还没有内容。配对、备份、移除设备的记录会按时间出现在这里。</p>
            {:else}
              <ul class="log-rows">
                {#each auditEvents as e (e.ts + ":" + e.action)}
                  {@const at = humanTime(e.ts, nowMs)}
                  <li>
                    <span class="log-text">{auditLine(e)}</span>
                    {#if at}<span class="log-time">{at}</span>{/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </div>
          <p class="hint">记录来自本机照片库与审计日志，不上传。</p>
        </section>
      {:else if page === "settings"}
        <section class="page" data-testid="page-settings">
          <div class="lede">
            <h2 class="headline">{t("ui.settings")}</h2>
          </div>
          <div class="cols">
            <div class="card grow">
              <h3>照片库</h3>
              {#if status?.library_dir}
                <code class="path">{status.library_dir}</code>
              {/if}
              <div class="row">
                <button class="primary" onclick={openLibrary}>{t("ui.open_library")}</button>
                <button onclick={chooseFolder}>{t("ui.change_library")}</button>
              </div>
              <!-- T-092: 磁盘水位（status.disk_free_bytes/disk_total_bytes）——
                   「可用 X GB / 共 Y GB」+ 细进度条（token 色）；任一字段
                   null（磁盘统计拿不到）整行连进度条一起隐藏。 -->
              {#if diskFree !== null && diskTotal !== null && diskPct !== null}
                <div class="disk-row">
                  <span>磁盘空间</span>
                  <span class="disk-val">可用 {diskFree} / 共 {diskTotal}</span>
                </div>
                <div class="disk-bar"><div class="disk-fill" style="width:{diskPct}%"></div></div>
              {/if}
              <p class="hint">更改位置重启后台服务后生效；已备份的照片不会自动搬家。</p>
            </div>
            <div class="col">
              <div class="card">
                <!-- DESK-02①: 更新通道零 UI——由构建推导（版本含 -test. →
                     test），旧 REL-02 通道选择行已删。 -->
                <div class="setting-row">
                  <span>软件更新</span>
                  <button onclick={() => checkForUpdate(true)}>检查更新</button>
                </div>
                <div class="setting-row">
                  <span>遇到问题？导出诊断包</span>
                  <button onclick={exportLogs}>{t("ui.export_logs")}</button>
                </div>
                <p class="hint">{t("ui.logs_hint")}</p>
              </div>
              <div class="card danger-card">
                <h3 class="danger-title">{t("ui.stop_service")}</h3>
                <p class="hint">{t("ui.stop_hint")}</p>
                <button class="danger" onclick={stopService}>{t("ui.stop_service")}</button>
              </div>
            </div>
          </div>
        </section>
      {/if}
    </main>
    <!-- T4 (H-10b): 配对状态机模态——二维码弹窗 + 允许/拒绝弹窗。 -->
    {#if showPairModal}
      <div class="modal-backdrop" onclick={closePairModal}>
        <div class="modal" onclick={(e) => e.stopPropagation()}>
          <h3>扫码添加手机</h3>
          {#if qrDataUrl}
            <img class="qr-lg" src={qrDataUrl} alt="配对二维码" />
            <!-- FIX-T3: 升级顺序地雷——旧 APK（≤0.3.0-test.2）只认 a=，
                 新码只带 r=，旧手机扫新码静默失败。把话说清：先升手机 App。 -->
            <p class="hint modal-hint modal-upgrade-note">
              {t("ui.qr_phone_version")}
            </p>
            <p class="hint modal-hint">
              用家人手机上的 P-Pass 扫这个码；手机发来的加入请求会自动出现在这里。
            </p>
            <div class="modal-actions">
              <button onclick={startPairing}>刷新二维码</button>
              <button class="primary" onclick={closePairModal}>关闭</button>
            </div>
          {:else}
            <p class="hint modal-hint">正在生成配对码…</p>
          {/if}
        </div>
      </div>
    {/if}

    {#if showConfirmModal && pendingList.length > 0}
      <div class="modal-backdrop">
        <div class="modal">
          <!-- UX-08: 多台同时扫码 → 一屏全列，逐行允许/拒绝，处理完该行
               消失，全清后列表关闭——不挤牙膏式顺序弹窗。 -->
          <h3>{pendingList.length > 1 ? `有 ${pendingList.length} 台设备请求加入` : "有设备请求加入"}</h3>
          <p class="hint modal-hint">确认是家人的手机吗？允许后它会出现在设备列表里。</p>
          <div class="pending-list">
            {#each pendingList as item}
              <!-- DEV-01: item 可能带 hint_match——这台手机以前配对过
                   （重装/清数据后重扫）。DEV-01b: 入口先隐藏——flag 关时
                   hint_match 分支不渲染，对话框与 DEV-01 之前完全一致
                   （主按钮「允许」= 作为新设备）；打开 flag 即恢复
                   「替换旧的」主按钮 + 「作为新设备」次级按钮。 -->
              <div class="pending-row">
                <div class="pending-info">
                  <span class="pending-name">{item.name}</span>
                  {#if MERGE_ENTRY_ENABLED && item.hint_match}
                    <span class="pending-hint">
                      这台手机重装过——可以替换原来的「{item.hint_match.name}」，保留它的备份记录
                    </span>
                  {/if}
                </div>
                <div class="pending-actions">
                  <button onclick={() => confirmPair(false, item.name)}>{t("ui.deny")}</button>
                  {#if MERGE_ENTRY_ENABLED && item.hint_match}
                    <button onclick={() => confirmPair(true, item.name)}>{t("ui.allow_new")}</button>
                    <button class="primary" onclick={() => confirmPair(true, item.name, item.hint_match.node_id)}>
                      {t("ui.allow_replace")}
                    </button>
                  {:else}
                    <button class="primary" onclick={() => confirmPair(true, item.name)}>{t("ui.allow")}</button>
                  {/if}
                </div>
              </div>
            {/each}
          </div>
        </div>
      </div>
    {/if}
    <!-- DESK-03: 大图查看——原图内存展示（不落盘），关闭即弃；
         「在 Finder 中显示」揭示 originals 里的原文件。 -->
    {#if photoViewer}
      <div class="modal-backdrop" onclick={() => (photoViewer = null)}>
        <div class="modal photo-modal" onclick={(e) => e.stopPropagation()}>
          <div class="photo-viewer-wrap">
            {#if viewerSrc}
              <img class="photo-viewer-img" src={viewerSrc} alt="" />
            {:else}
              <div class="photo-viewer-loading">加载中…</div>
            {/if}
          </div>
          <div class="modal-actions">
            <button onclick={revealPhotoInFinder} disabled={!viewerPath}>
              {t("ui.photos_open_in_finder")}
            </button>
            <button class="primary" onclick={() => (photoViewer = null)}>关闭</button>
          </div>
        </div>
      </div>
    {/if}
    <!-- T1: 版本号——报问题/排查时先知道装的是什么版本。 -->
    {#if displayVersion}
      <footer class="version-footer">
        <span>P-Pass v{displayVersion}</span>
        <!-- DESK-02①: 环境显式徽标——prerelease 构建琥珀小徽标（「测试版」），
             环境在 UI 上一眼可辨，不靠用户读懂 -test 后缀；正式构建只显示版本号。 -->
        {#if isTestBuild}
          <span class="env-badge">{t("ui.env_badge_test")}</span>
        {/if}
      </footer>
    {/if}
  </div>
{/if}

<style>
  /* All colours/typography come from assets/design/tokens.css (single
     source of truth). Meaning colours: green=safe, amber=waiting,
     red=act — nothing else carries meaning. */
  :global(body) {
    margin: 0;
    font-family: var(--pp-font-sans);
    background: var(--pp-paper);
    color: var(--pp-ink);
    font-size: var(--pp-body-min);
  }
  :global(html), :global(body), :global(#app) {
    height: 100%;
  }
  /* T-082: 键盘焦点统一用 token 色 outline，消灭系统默认蓝色焦点圈。
     :global 覆盖本窗口全部可聚焦元素（含 Wizard）。 */
  :global(:focus-visible) {
    outline: 2px solid var(--pp-ink);
    outline-offset: 2px;
  }

  /* ---- shell：侧栏 + 内容区（布局 v1） ---- */
  .shell {
    display: flex;
    height: 100vh;
    overflow: hidden;
  }
  .sidebar {
    width: 216px;
    flex: none;
    background: var(--pp-linen);
    border-right: 1px solid var(--pp-border);
    display: flex;
    flex-direction: column;
    padding: 16px 12px;
    box-sizing: border-box;
  }
  .brand {
    font-family: var(--pp-font-serif);
    font-size: 22px;
    font-weight: 500;
    padding: 4px 12px 16px;
  }
  nav {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .nav-item {
    text-align: left;
    padding: 10px 12px;
    border: none;
    border-radius: var(--pp-radius-control-sm);
    background: transparent;
    color: var(--pp-ink-60);
    font-family: inherit;
    font-size: 15px;
    font-weight: 500;
    cursor: pointer;
    min-height: 0;
  }
  .nav-item:hover {
    background: var(--pp-hairline);
  }
  .nav-item.active {
    background: var(--pp-ink);
    color: var(--pp-paper);
    font-weight: 700;
  }
  .service-pill {
    margin-top: auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 10px 12px;
    border-radius: var(--pp-radius-pill);
    font-size: 13px;
    font-weight: 600;
    background: var(--pp-idle-bg);
    color: var(--pp-ink-60);
  }
  .service-pill .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--pp-idle);
    flex: none;
  }
  .service-pill.ok {
    background: var(--pp-safe-bg);
    color: var(--pp-safe);
  }
  .service-pill.ok .dot {
    background: var(--pp-safe);
  }
  .service-pill.bad {
    background: var(--pp-act-bg);
    color: var(--pp-act);
  }
  .service-pill.bad .dot {
    background: var(--pp-act);
  }
  .content {
    flex: 1;
    overflow-y: auto;
    padding: 34px 38px;
    box-sizing: border-box;
  }
  .page {
    display: flex;
    flex-direction: column;
    gap: 22px;
    max-width: 880px;
  }
  .lede .headline {
    font-family: var(--pp-font-serif);
    font-size: 30px;
    font-weight: 400;
    line-height: 1.3;
    margin: 0;
  }
  .lede .sub {
    color: var(--pp-ink-40);
    font-size: 15px;
    margin: 8px 0 0;
  }

  /* wizard 全窗（首启向导独占，无侧栏） */
  .wizard-shell {
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

  /* ---- 卡片与行 ---- */
  .card {
    background: var(--pp-paper);
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-card);
    padding: 20px 22px;
  }
  .cols {
    /* T-082: 设计稿原文 display:flex;gap:22px;align-items:stretch——两卡等高 */
    display: flex;
    gap: 22px;
    align-items: stretch;
  }
  .cols .grow {
    flex: 1.2;
  }
  .cols .card:not(.grow) {
    flex: 1;
  }
  .col {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 22px;
  }
  .col .card {
    flex: none;
  }
  h3 {
    font-size: 15px;
    font-weight: 600;
    margin: 0 0 12px;
  }
  .pending-card {
    display: flex;
    align-items: center;
    gap: 16px;
    background: var(--pp-waiting-bg);
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-card);
    padding: 18px 22px;
  }
  .pending-text {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
  }
  .pending-text strong {
    font-size: 16px;
  }
  .pending-text span {
    font-size: 14px;
    color: var(--pp-ink-60);
  }
  .device-rows {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .device-rows li {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 0;
    border-bottom: 1px solid var(--pp-divider);
  }
  .device-rows.roomy li {
    padding: 14px 0;
    gap: 14px;
  }
  .device-rows li:last-child {
    border-bottom: none;
  }
  .statusdot {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    flex: none;
  }
  .statusdot.idle {
    background: var(--pp-idle);
  }
  /* T-091: 哨兵态（最近备份 >5 天）——行点与右侧文案用 ACT 色 */
  .statusdot.act {
    background: var(--pp-act);
  }
  /* T-092: 连接态点色——direct=safe 绿，relay=wait 琥珀（语义色仅此三种 +
     act，别的颜色不带含义） */
  .statusdot.safe {
    background: var(--pp-safe);
  }
  .statusdot.wait {
    background: var(--pp-waiting);
  }
  .dev-right.act {
    color: var(--pp-act);
  }
  .dev-name {
    flex: 1;
    font-weight: 600;
    font-size: 15px;
  }
  .dev-right {
    color: var(--pp-ink-40);
    font-size: 13.5px;
    flex: none;
  }
  /* T-082: 设备行两行结构（首行名字加粗、次行机型/连接状态槽位） */
  .dev-main {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }
  .dev-main .dev-name {
    flex: none;
    font-size: 16px;
  }
  /* NAME-01: 设备名可点击编辑——按钮化保持纸底墨字（hover 提亮），
     与行内其他动作（移除）同族但低调（无边框无底色，仅 hover 下划线）。 */
  .dev-name-btn {
    flex: none;
    font-size: 16px;
    font-weight: 600;
    color: var(--pp-ink);
    background: transparent;
    border: none;
    border-radius: var(--pp-radius-control-sm);
    padding: 2px 6px;
    margin-left: -6px;
    cursor: pointer;
    text-align: left;
    min-height: 0;
    font-family: inherit;
  }
  .dev-name-btn:hover {
    background: var(--pp-linen);
    text-decoration: underline;
    text-underline-offset: 3px;
  }
  .dev-rename {
    flex: none;
    font-size: 16px;
    font-weight: 600;
    font-family: inherit;
    color: var(--pp-ink);
    background: var(--pp-paper);
    border: 1.5px solid var(--pp-border-strong);
    border-radius: var(--pp-radius-control-sm);
    padding: 2px 6px;
    max-width: 260px;
  }
  .dev-rename:focus {
    outline: none;
    border-color: var(--pp-safe);
  }
  .dev-sub {
    color: var(--pp-ink-40);
    font-size: 13.5px;
    line-height: 1.5;
  }
  /* T-082: 已移除设备折叠器——展开后 ink-40 弱化，无删除线 */
  .removed-fold {
    margin-top: 12px;
    border-top: 1px solid var(--pp-divider);
    padding-top: 12px;
  }
  .removed-fold summary {
    cursor: pointer;
    color: var(--pp-ink-40);
    font-size: 14px;
    font-weight: 600;
  }
  .removed-name {
    color: var(--pp-ink-40);
    font-weight: 400;
  }
  /* T-092: 活动记录批次行——设计稿结构：文本左、时间右（baseline 对齐） */
  .log-rows {
    list-style: none;
    margin: 0;
    padding: 0;
  }
  .log-rows li {
    display: flex;
    align-items: baseline;
    gap: 14px;
    padding: 14px 0;
    border-bottom: 1px solid var(--pp-divider);
  }
  .log-rows li:last-child {
    border-bottom: none;
  }
  .log-text {
    font-size: 15px;
    font-weight: 500;
  }
  .log-time {
    margin-left: auto;
    flex: none;
    font-size: 13px;
    color: var(--pp-ink-40);
  }
  /* T-092: 设置页磁盘水位行 + 细进度条（设计稿：上分隔线、8px 圆角条，
     轨道 hairline、填充 ink——全部 token 色） */
  .disk-row {
    display: flex;
    justify-content: space-between;
    gap: 12px;
    border-top: 1px solid var(--pp-divider);
    margin-top: 14px;
    padding-top: 14px;
    font-size: 14px;
    font-weight: 600;
  }
  .disk-row .disk-val {
    color: var(--pp-ink-40);
    font-weight: 400;
  }
  .disk-bar {
    height: 8px;
    margin-top: 10px;
    background: var(--pp-hairline);
    border-radius: var(--pp-radius-pill);
    overflow: hidden;
  }
  .disk-fill {
    height: 100%;
    background: var(--pp-ink);
    border-radius: var(--pp-radius-pill);
  }
  .setting-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 10px 0;
    border-bottom: 1px solid var(--pp-divider);
    font-size: 15px;
    font-weight: 500;
  }
  .setting-row:last-of-type {
    border-bottom: none;
  }
  .danger-card {
    border-color: var(--pp-act);
    background: var(--pp-act-bg);
  }
  .danger-title {
    color: var(--pp-act);
  }
  .path {
    display: block;
    font-size: 14px;
    background: var(--pp-linen);
    border-radius: var(--pp-radius-control-sm);
    padding: 12px 16px;
    margin-bottom: 12px;
    word-break: break-all;
  }

  .row {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
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
    background: var(--pp-paper);
  }
  button.danger:hover {
    border-color: var(--pp-act);
    background: var(--pp-act-bg);
  }
  button:disabled {
    opacity: 0.5;
    cursor: default;
  }
  /* T-082: 设计稿——添加设备卡内容水平居中，标题保持左上 */
  .qr-card {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 12px;
  }
  .qr-card h3 {
    align-self: flex-start;
    margin: 0;
  }
  /* T-082: 二维码 148×148，白底（PNG 自带）、圆角 12、带边框（设计稿原文） */
  .qr {
    display: block;
    width: 148px;
    height: 148px;
    box-sizing: border-box;
    margin: 0;
    border: 1px solid var(--pp-border);
    border-radius: var(--pp-radius-control-sm);
    max-width: 100%;
  }
  .qr-hint {
    margin: 0;
    text-align: center;
  }
  .qr-fallback {
    align-self: stretch;
    text-align: center;
  }
  .qr-fallback summary {
    cursor: pointer;
    font-size: 13px;
    font-weight: 600;
    color: var(--pp-safe);
    list-style: none;
  }
  .qr-fallback summary::-webkit-details-marker {
    display: none;
  }
  .qr-fallback .qrtext {
    text-align: left;
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
  .version-footer {
    position: fixed;
    right: 14px;
    bottom: 8px;
    font-size: 11px;
    color: var(--pp-ink-40);
    opacity: 0.8;
    user-select: none;
    display: flex;
    align-items: center;
    gap: 6px;
  }
  /* DESK-02①: 环境徽标——prerelease 构建琥珀小徽标（测试版），
     环境在 UI 上一眼可辨；正式构建不渲染。 */
  .env-badge {
    display: inline-block;
    padding: 1px 7px;
    border-radius: 999px;
    background: var(--pp-act-bg);
    color: var(--pp-act);
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.02em;
  }
  /* T4: 配对状态机模态 */
  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(23, 21, 18, 0.45);
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 50;
  }
  .modal {
    background: var(--pp-paper);
    border-radius: var(--pp-radius-card);
    padding: 26px 30px 22px;
    width: 420px;
    max-width: 92vw;
    text-align: center;
    box-shadow: 0 18px 50px rgba(0, 0, 0, 0.28);
  }
  .qr-lg {
    width: 360px;
    max-width: 100%;
    image-rendering: pixelated;
    border-radius: var(--pp-radius-control-sm);
    margin: 14px 0 4px;
  }
  .modal-hint {
    margin: 12px 0 16px;
  }
  .modal-actions {
    display: flex;
    gap: 10px;
    justify-content: center;
    margin-top: 4px;
  }
  /* UX-08: pending 全量列表——一屏一行，逐行允许/拒绝 */
  .pending-list {
    display: flex;
    flex-direction: column;
    gap: 8px;
    margin-top: 4px;
    max-height: 300px;
    overflow-y: auto;
  }
  .pending-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    background: var(--pp-linen);
    border-radius: var(--pp-radius-control-sm);
    padding: 10px 12px;
  }
  .pending-info {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }
  .pending-name {
    font-weight: 600;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .pending-hint {
    color: var(--pp-act);
    font-size: 13px;
    line-height: 17px;
  }
  .pending-actions {
    display: flex;
    gap: 8px;
    flex: none;
  }
  .pending-actions button {
    min-width: 64px;
  }
  .hint {
    color: var(--pp-ink-40);
    font-size: 14px;
    margin: 10px 0 0;
    line-height: 1.55;
  }
  .card > .hint:first-of-type {
    margin-top: 0;
  }
  .card .row {
    margin-top: 12px;
  }
  .offline-card p:first-child {
    margin-top: 0;
  }
  .message {
    background: var(--pp-waiting-bg);
    border: 1px solid var(--pp-waiting);
    border-radius: var(--pp-radius-control);
    padding: 10px 14px;
    font-size: 15px;
    margin: 0 0 18px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
  }
  /* UX-08: 提示条右侧 × 手动关闭——弱化小按钮，不抢正文 */
  .message-close {
    background: none;
    border: none;
    color: var(--pp-ink-40);
    font-size: 18px;
    line-height: 1;
    padding: 2px 6px;
    cursor: pointer;
    flex: none;
    border-radius: 6px;
  }
  .message-close:hover {
    color: var(--pp-ink);
    background: var(--pp-linen);
  }

  /* ── DESK-03: 照片墙 ─────────────────────────────────────────── */
  .photo-wall {
    overflow: hidden; /* 卡片内滚动由页面容器负责，墙不撑破圆角 */
  }
  .photo-group {
    margin: 14px 0 8px;
    font-size: 13px;
    font-weight: 600;
    color: var(--pp-ink-60, #5c5347);
  }
  .photo-group:first-child {
    margin-top: 0;
  }
  .photo-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(110px, 1fr));
    gap: 6px;
  }
  .photo-cell {
    position: relative;
    aspect-ratio: 1;
    padding: 0;
    border: none;
    border-radius: var(--pp-radius-control-sm, 6px);
    background: var(--pp-border, #e8e0d5);
    overflow: hidden;
    cursor: zoom-in;
  }
  .photo-cell:hover {
    outline: 2px solid var(--pp-ink);
    outline-offset: 2px;
  }
  .video-badge {
    position: absolute;
    right: 5px;
    bottom: 5px;
    font-size: 11px;
    color: #fff;
    background: rgba(0, 0, 0, 0.55);
    border-radius: 4px;
    padding: 1px 5px;
    pointer-events: none;
  }
  .photo-sentinel {
    height: 24px;
    text-align: center;
    color: var(--pp-ink-60, #5c5347);
    font-size: 12px;
  }
  /* 大图 modal：图片区域限高、object-contain 保完整（大图看全貌优先） */
  .photo-modal {
    width: min(88vw, 880px);
  }
  .photo-viewer-wrap {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 260px;
    max-height: 70vh;
    overflow: hidden;
    background: #14100c;
    border-radius: var(--pp-radius-control-sm, 6px);
  }
  .photo-viewer-img {
    max-width: 100%;
    max-height: 70vh;
    object-fit: contain;
  }
  .photo-viewer-loading {
    color: #cbbfa8;
    padding: 40px;
    font-size: 13px;
  }
</style>
