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
  // DESK-07: shadcn-svelte 组件（组件代码进仓库 src/lib/components/ui/，
  // 不是 node_modules 黑箱；Tailwind 工具类全局可用）
  import { Button } from "$lib/components/ui/button";
  import { Card } from "$lib/components/ui/card";
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
  // 2026-08-13: icon 字段供 <1080px 收起态的 64px 图标轨使用（设计稿
  // 离线版 v2「第 3 轮响应式」新增，图标形状原样照抄设计稿 SVG path）。
  // ≥1080px 展开态不画图标，跟设计稿交互原型一致（原型的 nav 只有
  // label，没有 icon——图标是收起态专属，不是随时都显示的装饰）。
  const NAV = [
    {
      id: "overview",
      label: "总览",
      icon: '<path d="M3 10.5 12 3l9 7.5"></path><path d="M5 9.5V21h14V9.5"></path>',
    },
    {
      id: "photos",
      label: t("ui.nav_photos"),
      icon: '<rect x="3" y="4" width="18" height="16" rx="2"></rect><circle cx="9" cy="10" r="2"></circle><path d="m21 16-5-5-9 9"></path>',
    },
    {
      id: "devices",
      label: "家人与设备",
      icon: '<rect x="6" y="2.5" width="12" height="19" rx="2.5"></rect><path d="M11 18.5h2"></path>',
    },
    {
      id: "log",
      label: "活动记录",
      icon: '<circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3.5 2"></path>',
    },
    {
      id: "settings",
      label: "设置",
      icon: '<circle cx="12" cy="12" r="3"></circle><path d="M19 12a7 7 0 0 0-.14-1.4l2.1-1.63-2-3.46-2.48 1a7 7 0 0 0-2.42-1.4L13.7 2.5h-3.4l-.36 2.61a7 7 0 0 0-2.42 1.4l-2.48-1-2 3.46 2.1 1.63A7 7 0 0 0 5 12c0 .48.05.94.14 1.4l-2.1 1.63 2 3.46 2.48-1a7 7 0 0 0 2.42 1.4l.36 2.61h3.4l.36-2.61a7 7 0 0 0 2.42-1.4l2.48 1 2-3.46-2.1-1.63c.09-.46.14-.92.14-1.4Z"></path>',
    },
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
  // DAE-04: daemon 版本落后于桌面壳（更新装好了但旧 daemon 进程还在跑）——
  // 设置页「重启后台服务」按钮的唯一显示条件。版本一致/读不到时不显示，
  // 避免用户瞎点误杀正常运行的服务。
  const daemonStale = $derived(
    !!version && !!status?.version && !sameRelease(version, status.version)
  );
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
  // DESK-05: 拆成 设备/事件 两列喂表格——设备列解析 actor 名称，事件列
  // 只留动作文本（原「<设备名> 备份完成」式前缀并入设备列）。
  // 照片墙同步卡: detail 里机器可读字段（ingested= duplicates=）翻译成
  // 人话；asset.removed_external 只留文件名（全路径是噪音）。
  function auditWho(e) {
    const d = e.detail ?? "";
    const who = devices.find((x) => x.node_id === e.actor)?.name ?? null;
    if (who) return who;
    // 配对类事件 detail 里是设备名（actor 为 null 时兜底）。
    if (e.action.startsWith("pair.") && d) return d;
    if (e.actor) return `${e.actor.slice(0, 8)}…`;
    return "本机";
  }
  function auditText(e) {
    const d = e.detail ?? "";
    switch (e.action) {
      case "pair.requested":
        return "请求加入";
      case "pair.accepted":
        return "已加入";
      case "pair.denied":
        return "加入被拒绝";
      case "backup.started":
        return "开始备份";
      case "backup.finished": {
        // detail 是机器可读 "ingested=N duplicates=M"（router.rs 备份
        // 提交审计）——翻译成人话；解析失败回退原文（绝不吞）。
        const m = /ingested=(\d+)\s+duplicates=(\d+)/.exec(d);
        if (m) return `备份完成：新增 ${m[1]} 张，去重 ${m[2]} 张`;
        return `备份完成（${d}）`;
      }
      case "asset.removed_external":
        // detail "originals missing: <rel_path>"（SYNC-01 对账/WATCH-01
        // 秒级监听清索引）——只留文件名，全路径是噪音。
        return `外部删除（${shortName(d)}）`;
      case "device.renamed": {
        // detail "{旧名} -> {新名} ({64位hex node_id})"（ipc.rs 改名审计
        // 写入）——node_id 是取证用的，不给用户看，只留改名前后的名字，
        // 不然一条动态挤进 64 位十六进制字符串，总览摘要卡/活动记录页
        // 都会被撑爆换行（用户实测反馈）。
        const m = /^(.*) -> (.*) \([0-9a-f]{64}\)$/.exec(d);
        if (m) return `改名：${m[1]} → ${m[2]}`;
        return `已改名（${d}）`;
      }
      case "device.revoked":
        return "已移除设备";
      case "device.unpaired":
        return "主动断开连接";
      case "device.connected":
        // PRES-01: hello 心跳进活动流——「小红 连接了」（10 分钟去重，
        // 防锁屏重连刷屏）。
        return "连接了";
      case "backup.commit":
        return `备份提交（${shortName(d)}）`;
      case "external.delete":
        return `外部删除（${shortName(d)}）`;
      default:
        return `${e.action} ${d}`.trim();
    }
  }
  // 审计 detail 常带全路径/机器前缀——只留最后一段文件名（噪音过滤，
  // 与 visibleAudit 的 ingest.* 过滤同一原则）。没有路径就原样返回。
  function shortName(d) {
    const s = String(d ?? "");
    const i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"));
    return i >= 0 ? s.slice(i + 1) : s;
  }
  // DESK-05: 活动表格只展示设备级事件——ingest.* 逐文件行是全路径噪音
  // （备份完成行的 ingested= 汇总已覆盖数量），不参与展示。数据层不动。
  const visibleAudit = $derived(
    auditEvents.filter((e) => !e.action.startsWith("ingest."))
  );
  // 设计稿"本周"统计条：只取真实能从审计里推出来的两项（新备份/去重
  // 跳过，backup.finished 的 ingested=/duplicates= 汇总，过去 7 天）；
  // 设计稿画的第三项「重试成功」在当前审计事件里没有对应的真实语义
  // （没有 retry 相关的 action），不编造数字，先只做这两项。
  const WEEK_MS = 7 * 24 * 60 * 60 * 1000;
  const weekStats = $derived.by(() => {
    let added = 0, dup = 0;
    const cutoff = nowMs - WEEK_MS;
    for (const e of auditEvents) {
      if (e.action !== "backup.finished" || e.ts < cutoff) continue;
      const m = /ingested=(\d+)\s+duplicates=(\d+)/.exec(e.detail ?? "");
      if (m) {
        added += Number(m[1]);
        dup += Number(m[2]);
      }
    }
    return { added, dup };
  });

  // PRES-01: sub 槽接 devices.list[].presence 三档（online 优先展示连接
  // 路径事实：已直连/经中继；心跳新鲜无活连接 → 「在线」；recent →
  // 「x 分钟前在线」；offline → 「离线，最后在线 <时间>」/「等待下次备份
  // 上报」）。哨兵红优先级高于 presence——一台设备两个真相时先说要紧的。
  // DESK-07: 设备行状态点色 map（语义色仅 safe/wait/idle/act 四种，
  // 颜色值全来自 tokens.css，见其注释）
  const DOT_BG = { idle: "bg-idle", act: "bg-act", safe: "bg-safe", wait: "bg-waiting" };

  /* DESK-08: 迁移后的按钮族常量——原手写 button 规则的 Tailwind 等价
     （base=透明底+1.5px border-strong；primary=ink 底纸字；danger=透明底
     act 字 act 边；link=纯文字）。所有迁移页共用，保证全站按钮一致。 */
  const BTN =
    "h-11 min-h-11 rounded-md border border-ink px-[18px] text-[15px] font-bold hover:bg-ink-hover";
  const BTN_OUTLINE =
    "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-transparent px-[18px] text-[15px] font-semibold text-ink-60 hover:bg-linen hover:text-ink-60";
  const BTN_DANGER =
    "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-paper px-[18px] text-[15px] font-semibold text-act hover:border-act hover:bg-act-bg hover:text-act";
  const BTN_LINK =
    "h-auto min-h-0 rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px]";

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
      right: backupTime ? `最近备份 ${backupTime}` : "还没备份过",
    };
  }

  // 设计稿离线版：总览标题副标题是"全家 N 张照片…"+"最近一次备份：
  // <时间> · 来自 <设备>"，不是"已配对设备 N 台 · 照片库 M 张"——
  // 取所有设备水位里 last_backup_at 最大的那条，真实数据，没有就
  // 优雅退回旧文案（没备份过/watermarks 还没加载完时不假装有数据）。
  const lastBackupOverall = $derived.by(() => {
    let best = null;
    for (const d of devices) {
      if (d.revoked) continue;
      const wm = watermarks[d.node_id];
      if (!wm?.last_backup_at) continue;
      if (!best || wm.last_backup_at > best.at) best = { at: wm.last_backup_at, name: d.name };
    }
    return best;
  });
  // 设计稿离线版：总览水位卡只放"需要留意的 + 最近动过的"，不是全量
  // 平铺——告警设备（alert）永远全show，正常设备只show 前 OK_CAP 个，
  // 剩下的收进"一切正常的还有 N 台"链接（点进「家人与设备」看全部，
  // 那边才是全量真相，这里只是总览摘要）。
  const OVERVIEW_OK_CAP = 2;
  const waterRows = $derived.by(() => {
    const active = devices.filter((d) => !d.revoked);
    const withRow = active.map((d) => ({ d, row: deviceRow(d, nowMs) }));
    const alerts = withRow.filter((x) => x.row.alert);
    const ok = withRow.filter((x) => !x.row.alert);
    return {
      shown: [...alerts, ...ok.slice(0, OVERVIEW_OK_CAP)],
      moreOk: Math.max(0, ok.length - OVERVIEW_OK_CAP),
    };
  });

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

  /* 扫码有困难的退路：复制配对串本文，用户自己找办法传给手机（隔空
   * 投送/微信自己发自己）。剪贴板失败静默不打扰——这是个次要退路，
   * 不是关键路径。 */
  async function copyPairString() {
    if (!qrText) return;
    try {
      await navigator.clipboard.writeText(qrText);
      flashMessage("配对串已复制");
    } catch {
      // 静默——剪贴板权限问题不值得打断用户，主路径还是扫码。
    }
  }

  /* 设计稿 v2 对齐：卡片级「无法扫码？复制配对串」——不打开弹窗，静默
   * 取一次配对串（pairing.start 每次调用即轮换，与弹窗「刷新二维码」
   * 同一语义）复制；失败静默。主路径仍是扫码，这是退路。 */
  async function copyPairQuiet() {
    try {
      const r = qrText || (await call("pairing.start")).qr;
      qrText = r;
      await navigator.clipboard.writeText(r);
      flashMessage("配对串已复制");
    } catch {
      // 静默
    }
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
    // DESK-05 + 照片墙同步: activity.appended（备份审计落地）/
    // device.changed（水位推进）/ timeline.invalidated（WATCH-01 秒级
    // 监听 + SYNC-01 对账：Finder 删除/新增）任一发生都要让照片墙感知
    // 到——但 2026-08-17 改成增量合并，不再整墙清空重拉（见
    // syncPhotosWallIncremental 注释：清空重拉会让已经渲染好的缩略图
    // 全部销毁重建，来一次事件卡一下，照片多的库尤其明显）。
    if (
      name === "activity.appended" ||
      name === "device.changed" ||
      name === "timeline.invalidated"
    ) {
      syncPhotosWallIncremental();
    }
    // 事件帧 {event, data}——data 是占位/增量提示，具体状态一律全量拉。
    refresh();
  }

  // 照片墙硬重置——手动"刷新"按钮专用，用户主动要求"就要最新真相"时
  // 才整墙清空重拉，代价（缩略图重新请求+滚动位置归零）用户自己选的，
  // 不是背着用户在后台悄悄发生。
  function resetPhotosWall() {
    photosLoaded = false;
    photos = [];
    photosNext = null;
  }

  // 2026-08-17（用户复核纠正）：墙是按拍摄时间排的（daemon
  // asset_repo.rs::timeline_page 「ORDER BY COALESCE(taken_at, 0) DESC,
  // hash ASC」），不是按同步/到达时间——补录的老照片 taken_at 可能很
  // 老，直接插到数组最前面会把它排到"最新"，弄错时间线顺序。这里跟
  // 后端用同一个排序键做正确位置的插入，不是无脑塞最前面。
  function comparePhotoOrder(a, b) {
    const ta = a.taken_at ?? 0;
    const tb = b.taken_at ?? 0;
    if (ta !== tb) return tb - ta;
    return a.hash < b.hash ? -1 : a.hash > b.hash ? 1 : 0;
  }
  function insertPhotoSorted(arr, item) {
    let lo = 0;
    let hi = arr.length;
    while (lo < hi) {
      const mid = (lo + hi) >>> 1;
      if (comparePhotoOrder(arr[mid], item) <= 0) lo = mid + 1;
      else hi = mid;
    }
    arr.splice(lo, 0, item);
  }

  // daemon 事件驱动的照片墙同步改成增量合并，不清空重拉——之前
  // resetPhotosWall 把 photos 置空再整页重新拉取，Svelte 的
  // {#each g.items as item (item.hash)} keyed diff 面对"先清空再填入"
  // 这种中间态无从复用，等于把所有 PhotoThumb 组件实例（含已经拉到手的
  // 缩略图）全部销毁重建，即使绝大多数照片压根没变——库大/事件密集时
  // 就是用户反馈的"卡顿"。改法：拉一次最新第一页当真相，本地还没有的
  // hash 按 comparePhotoOrder 插入正确位置，已经渲染的条目原样不动，
  // 一次 IPC/PhotoThumb 请求都不多花。**已加载窗口之外**的补录老照片
  // （page-1 压根拉不到，因为它按 taken_at 排且只取最新一页）这版不
  // 处理——用户滚动到那个时间范围时，正常分页 loadPhotosPage 会照常
  // 拉到，不需要特殊代码；深层分页内的删除同理靠 SYNC-01 每小时对账 +
  // 手动"刷新"兜底，不是这次要解决的卡顿主因。
  async function syncPhotosWallIncremental() {
    if (!photosLoaded) return; // 还没首次加载过，交给进页时的 $effect 首拉
    try {
      const r = await call("timeline.page", { cursor: null, limit: PHOTOS_PAGE_SIZE });
      const fresh = r.items ?? [];
      const known = new Set(photos.map((p) => p.hash));
      const arrivals = fresh.filter((it) => !known.has(it.hash));
      if (arrivals.length > 0) {
        const next = [...photos];
        for (const item of arrivals) insertPhotoSorted(next, item);
        photos = next;
      }
    } catch (_) {
      // 静默失败——不影响墙上已有内容，下次事件/60s 兜底再试。
    }
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

  // DAE-04: 「桌面壳自己的版本」与「daemon 版本」是否同一次发布——只比
  // 核心三段数字，忽略 v 前缀和 -test.N 后缀：release 里 daemon 报
  // "v0.3.3-test.1"、壳报 "0.3.3"（tauri.conf.json），是同一份；更新
  // 装好后壳变 0.3.4、daemon 还是 v0.3.3-test.1 → 核心不同 → 真不一致。
  function sameRelease(a, b) {
    const core = (s) =>
      String(s)
        .replace(/^v/i, "")
        .split("-")[0]
        .split(".")
        .map((x) => parseInt(x, 10) || 0);
    const ca = core(a);
    const cb = core(b);
    return (
      ca.length === 3 &&
      cb.length === 3 &&
      ca[0] === cb[0] &&
      ca[1] === cb[1] &&
      ca[2] === cb[2]
    );
  }

  // DAE-04: 桌面壳更新后手动重启后台服务——杀旧 daemon，靠 launchd 拉起
  // 磁盘上的新版本（Windows 无 KeepAlive 语义，Rust 命令内显式重拉）。
  // 成功/失败都明说：版本真变了才报成功；没变 = 服务文件没更新，提示重装。
  let restartingService = $state(false);
  async function restartDaemonProcess() {
    const yes = await confirmDialog(t("ui.restart_service_confirm_body"), {
      title: t("ui.restart_service_confirm_title"),
      kind: "warning",
    });
    if (!yes) return;
    restartingService = true;
    try {
      const r = await invoke("restart_daemon_process");
      if (r?.changed) {
        flashMessage(
          r.old_version
            ? t("ui.restart_service_ok", { from: r.old_version, to: r.new_version })
            : t("ui.restart_service_started", { version: r.new_version })
        );
      } else {
        flashMessage(t("ui.restart_service_no_change", { version: r.new_version ?? "?" }));
      }
    } catch (e) {
      flashMessage(t("ui.restart_service_failed", { err: String(e) }));
    } finally {
      restartingService = false;
    }
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
            title={n.label}
            onclick={() => go(n.id)}
          >
            <svg class="nav-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">{@html n.icon}</svg>
            <span class="nav-label">{n.label}</span>
          </button>
        {/each}
      </nav>
      <!-- 顶部徽章只表示服务状态（UX-04），落位侧栏底部胶囊；<1080px
           收起态缩成纯色点（设计稿：服务状态缩成底部绿点）。 -->
      <div class="service-pill" class:ok={online} class:bad={!online} title={online ? "后台服务运行中" : t("ui.offline_banner")}>
        <span class="dot"></span>
        <span class="service-label">{online ? "后台服务运行中" : t("ui.offline_banner")}</span>
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
          <div>
            <!-- 2026-08-13：设计稿离线版标题带真实照片数——"全家的照片"
                 换成"全家 N 张照片"，photoCount 没拿到时退回原句（不写
                 假数字）。 -->
            <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3] text-ink">
              {#if photoCount !== null}全家 {photoCount} 张照片，安全地住在这台电脑上。{:else}全家的照片，安全地住在这台电脑上。{/if}
            </h2>
            <!-- 副标题：有真实"最近一次备份"数据就用设计稿的格式，没有
                 （比如还没配对过/一次都没备份过）就退回旧的配对数摘要，
                 不硬凑一句假话。 -->
            <p class="mt-[6px] text-[14px] text-ink-40">
              {#if lastBackupOverall}
                最近一次备份：{humanTime(lastBackupOverall.at, nowMs)} · 来自 {lastBackupOverall.name}
              {:else}
                {t("ui.paired_count", { n: pairedCount })}{#if photoCount !== null}{` · 照片库 ${photoCount} 张`}{/if}
              {/if}
              {#if status && status.revoked > 0}{t("ui.revoked_count", { n: status.revoked })}{/if}
            </p>
          </div>

          {#if !online}
            <Card class="gap-0 rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
              <p class="m-0 text-[13px] leading-[1.6] text-ink-40">{t("ui.offline_action")}</p>
              <Button class="mt-[12px] self-start {BTN}" disabled={starting} onclick={startDaemonNow}>
                {starting ? t("ui.starting") : t("ui.start_service")}
              </Button>
              <p class="text-[13px] leading-[1.6] text-ink-40">{t("ui.refresh_hint")}</p>
            </Card>
          {:else}
            {#if pendingCount > 0 && !showConfirmModal}
              <div class="flex items-center gap-[16px] rounded-xl border border-border bg-waiting-bg px-[22px] py-[18px]">
                <div class="flex flex-1 flex-col gap-[3px]">
                  <strong class="text-[16px]">{t("diag.desktop.pairing")}</strong>
                  <!-- 设计稿 v2：横幅直接点名刚扫码的设备（pendingList 里
                       有真实名字）；列表为空时退回数量摘要（老 daemon 过渡）。 -->
                  {#if pendingList.length > 0}
                    <span class="text-[14px] text-ink-60">{t("ui.pending_banner_text", { name: pendingList[0].name })}</span>
                  {:else}
                    <span class="text-[14px] text-ink-60">{t("ui.pending_pairs", { n: pendingCount })}</span>
                  {/if}
                </div>
                <div class="flex flex-none flex-wrap gap-[10px]">
                  <Button variant="outline" class="h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-transparent px-[18px] text-[15px] font-semibold text-ink-60 hover:bg-linen hover:text-ink-60" onclick={() => confirmPair(false)}>{t("ui.deny")}</Button>
                  <Button class="h-11 min-h-11 rounded-md border border-ink px-[18px] text-[15px] font-bold" onclick={() => confirmPair(true)}>{t("ui.allow")}</Button>
                </div>
              </div>
            {/if}

            <!-- 2026-08-17：总览卡片区改功能驱动布局（用户拍板：桌面端
                 不再逐屏对设计稿，按功能优先级+屏幕尺寸各自最优排布）。
                 内容优先级（非"操作优先展示其次"的二元对立——总览的核心
                 功能就是「一眼确认备份没坏」，这才是大多数人打开这个
                 页面的原因，比"加设备"这种低频动作更该占主位）：
                 ①水位卡=核心状态，永远第一、永远最大；②添加设备=常驻
                 但低频的动作，次要位置；③最近动静=锦上添花的补充信息，
                 之前 <1440px 直接整卡消失是"設計稿驱动"年代的遗留（凑
                 三栏才加的卡，容不下就砍掉）——现在改成"任何尺寸都在，
                 只是密度/位置跟着可用空间变"：用 grid 而不是 flex+hidden，
                 大屏三栏并排，中屏两栏+第三卡沉到下面占满宽度，小屏单栏
                 全部竖排，没有哪个尺寸会突然"少一块内容"。 -->
            <!-- 2026-08-17：items-start 改等高（不设 align-items，grid 默认
                 stretch）——功能驱动阶段不用再守"卡片不等高"的旧设计规则
                 （T-082 反转过一次是为了贴设计稿，现在不追设计稿了）；
                 中屏两栏并排时"添加设备"卡内容天然比"备份状态"空
                 状态多，不等高会让水位卡下面露出一大块空白背景。 -->
            <div class="grid grid-cols-1 gap-[22px] min-[1080px]:grid-cols-2 min-[1440px]:grid-cols-3">
              <Card class="gap-0 rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
                <h3 class="mb-[12px] text-[15px] font-semibold">备份状态</h3>
                {#if devices.filter((d) => !d.revoked).length === 0}
                  <!-- 2026-08-17：等高后空状态垂直居中——不然矮内容顶在
                       卡片顶部，下面一截空白显得像没做完。 -->
                  <div class="flex flex-1 items-center justify-center">
                    <p class="m-0 text-[13px] leading-[1.6] text-ink-40">{t("ui.no_devices")}</p>
                  </div>
                {:else}
                  <ul class="m-0 list-none p-0">
                    {#each waterRows.shown as { d, row }}
                      <li class="flex items-center gap-[10px] border-b border-divider py-[10px] last:border-b-0">
                        <!-- T-091: 右侧接 device.watermarks 真数据（设计稿总览
                             水位卡为单行结构）。T-092: 行点变四色——哨兵 act >
                             连接态（direct=safe / relay=wait / offline·unknown=idle）。 -->
                        <span class="h-[9px] w-[9px] flex-none rounded-full {DOT_BG[row.dot]}"></span>
                        <span class="flex-1 text-[15px] font-semibold">{d.name}</span>
                        <span class="flex-none text-[13.5px] {row.alert ? 'text-act' : 'text-ink-40'}">{row.right}</span>
                      </li>
                    {/each}
                  </ul>
                  {#if waterRows.moreOk > 0}
                    <button class="h-auto min-h-0 rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px] mt-px self-start text-safe hover:text-safe" onclick={() => go("devices")}
                      >一切正常的还有 {waterRows.moreOk} 台 ›</button
                    >
                  {/if}
                {/if}
              </Card>

              <!-- 卡片本身不居中——标题、说明文字都是左对齐的普通文本；
                   只有按钮内文字（Button 基类自带 justify-center）和底部
                   「无法扫码」退路是居中的。 -->
              <!-- T4 (H-10b): 二维码不再是常驻卡片——点按钮弹窗出码，配对完
                   状态消失；扫码后的允许/拒绝也走模态。 -->
              <Card class="flex flex-col gap-[12px] rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
                <h3 class="mb-0 text-[15px] font-semibold">{t("ui.add_device")}</h3>
                <p class="m-0 flex-1 text-[13px] leading-[1.6] text-ink-40">点击后会放大显示一个配对二维码，用家人手机上的 P-Pass 扫一下；扫到后二维码自动收起，回到这里确认「允许加入」。</p>
                <Button class="h-11 min-h-11 w-full rounded-md border border-ink px-[18px] text-[15px] font-bold" onclick={startPairing}>{t("ui.generate_qr")}</Button>
                <!-- 设计稿 v2：无法扫码的退路提升到卡片级——不打开弹窗也
                     能复制配对串（copyPairQuiet 静默取串，主路径仍是扫码）。 -->
                <button class="h-auto min-h-0 w-full rounded-md border-none bg-transparent px-0 py-[2px] text-center text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px] text-safe hover:text-safe" onclick={copyPairQuiet}>{t("ui.qr_fallback")}</button>
              </Card>

              <!-- 「最近动静」摘要卡——不再靠 hidden+断点整卡消失。中屏
                   （1080-1439px）沉到第二行占满两栏宽度；大屏（≥1440px）
                   回到第三栏；小屏（<1080px）跟其它卡一样单栏竖排。数据
                   是活动记录前 3 条，复用同一套 auditWho/auditText，不是
                   另开一套数据源。 -->
              <Card class="flex flex-col gap-[12px] rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px] min-[1080px]:col-span-2 min-[1440px]:col-span-1">
                <h3 class="mb-0 text-[15px] font-semibold">最近动静</h3>
                <!-- 2026-08-17：内容包一层 flex-1——大屏三栏等高时这张卡
                     内容天然比左边两张少（最多 3 行），没有这层撑底的话
                     链接会紧贴在短内容下面、卡片下半段留一截空白，看起来
                     跟左边两张卡"高度不一样"（其实外框是等高的，只是内容
                     没撑满，视觉上像矮了一截）。 -->
                <div class="flex-1">
                  {#if visibleAudit.length === 0}
                    <p class="m-0 text-[13px] leading-[1.6] text-ink-40">还没有活动记录。</p>
                  {:else}
                    <!-- 单行紧凑文案（设备+事件+相对时间连成一行，不分列、
                         行间不加分隔线），跟主活动记录页的双列卡片行是两种
                         密度，故意不共用 .log-rows。 -->
                    <ul class="m-0 flex list-none flex-col gap-[10px] p-0 text-[14px] text-ink">
                      {#each visibleAudit.slice(0, 3) as e (e.ts + ":" + e.action)}
                        {@const at = humanTime(e.ts, nowMs)}
                        <li><b class="font-semibold">{auditWho(e)}</b> {auditText(e)}{#if at} · {at}{/if}</li>
                      {/each}
                    </ul>
                  {/if}
                </div>
                <button class="h-auto min-h-0 self-start rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold hover:bg-transparent hover:underline hover:underline-offset-[3px] text-safe hover:text-safe" onclick={() => go("log")}>全部活动记录 ›</button>
              </Card>
            </div>
          {/if}
        </section>
      {:else if page === "devices"}
        <!-- DESK-07: 本页已迁到 Tailwind CSS + shadcn-svelte（Button/Card）。
             样式一律工具类，不再吃 App.svelte 手写 CSS；数据流与交互逻辑
             （改名/移除/状态推导）一字未动。像素基准（列表贴边 18px 22px、
             移除=纯文字链接、标题 28px/副标题 14px/提示 13px）验收见卡记录。 -->
        <section class="page" data-testid="page-devices">
          <div class="lede">
            <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">家人与设备</h2>
            <p class="mt-[6px] text-[14px] text-ink-40">{t("ui.devices_paired_line", { n: pairedCount })}</p>
          </div>
          <Card class="gap-0 rounded-xl border border-border py-0 shadow-none ring-0 ring-transparent">
            {#if devices.length === 0}
              <p class="m-0 px-[22px] py-[18px] text-[13px] leading-[1.6] text-ink-40">{t("ui.no_devices")}</p>
            {:else}
              <!-- T-082: 设计稿两行结构——首行设备名加粗，次行「机型 · 连接状态」
                   槽位；daemon 尚未暴露机型/连接事实，数据未接前显示中性占位，
                   不捏造「已直连」。不再渲染原始 role 字串。 -->
              {@const activeDevices = devices.filter((d) => !d.revoked)}
              {@const removedDevices = devices.filter((d) => d.revoked)}
              {#if activeDevices.length === 0}
                <p class="m-0 px-[22px] py-[18px] text-[13px] leading-[1.6] text-ink-40">{t("ui.no_devices")}</p>
              {:else}
                <ul>
                  {#each activeDevices as d}
                    {@const row = deviceRow(d, nowMs)}
                    <li class="flex items-center gap-[14px] border-b border-divider px-[22px] py-[18px] last:border-b-0">
                      <!-- T-091: 哨兵行 ACT 色 + 「需要看看」；T-092: 连接态点色
                           （direct=safe 绿，relay=wait 琥珀）——语义色仅此四种 -->
                      <span class="h-[9px] w-[9px] flex-none rounded-full {DOT_BG[row.dot]}"></span>
                      <span class="flex flex-1 flex-col items-start gap-[2px]">
                        {#if renameTarget?.nodeId === d.node_id}
                          <!-- NAME-01: 改名输入框——回车保存 / Esc 取消 /
                               失焦保存（空名与未改动不提交）。 -->
                          <input
                            class="max-w-[260px] flex-none self-start rounded-sm border-[1.5px] border-border-strong bg-paper px-[6px] py-[2px] font-sans text-[16px] font-semibold text-ink focus:border-safe focus:outline-none"
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
                          <!-- NAME-01: 设备名可点击编辑——Button link 变体保持
                               纸底墨字（hover 提亮 + 下划线），与移除按钮同族但低调。
                               2026-08-17：shadcn Button 基类自带
                               justify-center，父容器 flex-col 默认拉伸满宽会把
                               名字挤到行中间（design v2 对齐轮实测发现）——
                               self-start + justify-start 双保险钉死左对齐。 -->
                          <Button
                            variant="link"
                            class="-ml-[6px] h-auto min-h-0 flex-none self-start justify-start rounded-sm border-0 border-none px-[6px] py-[2px] text-left text-[16px] leading-[1.38] font-semibold text-ink hover:bg-linen hover:underline hover:underline-offset-[3px]"
                            title={t("ui.rename")}
                            onclick={() => startRename(d)}
                          >{d.name}</Button>
                        {/if}
                        <span class="text-[13.5px] leading-[1.5] text-ink-40">{row.sub}</span>
                      </span>
                      <span class="flex-none text-[13.5px] {row.alert ? 'text-act' : 'text-ink-40'}">{row.right}</span>
                      <Button
                        variant="link"
                        class="h-auto min-h-0 rounded-sm border-0 border-none px-[4px] py-[8px] text-[14px] font-semibold text-act no-underline hover:bg-act-bg hover:underline hover:underline-offset-[3px]"
                        onclick={() => revoke(d.node_id, d.name)}
                      >{t("ui.remove")}</Button>
                    </li>
                  {/each}
                </ul>
              {/if}
              {#if removedDevices.length > 0}
                <!-- T-082: 已移除设备折叠为展开器，展开后用 ink-40 弱化，
                     不再划线平铺。 -->
                <details class="mt-[12px] border-t border-divider px-[22px] pt-[12px]">
                  <summary class="cursor-pointer text-[14px] font-semibold text-ink-40">已移除设备 {removedDevices.length} 台</summary>
                  <ul>
                    {#each removedDevices as d}
                      <li class="flex items-center gap-[14px] py-[14px]">
                        <span class="h-[9px] w-[9px] flex-none rounded-full bg-idle"></span>
                        <span class="flex-1 text-[15px] font-normal text-ink-40">{d.name}</span>
                      </li>
                    {/each}
                  </ul>
                </details>
              {/if}
            {/if}
          </Card>
          <!-- 设计稿 v2：区块间距靠 .page 的 flex gap(22px)统一撑开，
               这里不再叠加 mt——叠加会让卡片到提示文字的间距变成 32px，
               跟标题到卡片的 22px 不一致（design v2 是整段 20px 等距）。 -->
          <p class="text-[13px] leading-[1.6] text-ink-40">「经中继」= 直连不通时走加密中转，中继看不到照片内容，速度可能慢一些。移除设备会让它立刻失去访问权限——危险操作只放在电脑上。</p>
        </section>
      {:else if page === "photos"}
        <!-- DESK-03: 照片墙——与手机时间线同一数据源（query.timeline +
             thumb.get），本机直连 daemon 拉取；分组 今天/本月/更早；
             点开 = 原图内存查看（不落盘）+「在 Finder 中显示」原文件。 -->
        <section class="page" data-testid="page-photos">
          <!-- DESK-08: 照片页已迁 Tailwind + 组件库（Card + Button）；数据流
               （timeline 拉取/分组/查看大图/哨兵加载）一字未动。 -->
          <div class="flex items-start justify-between gap-[12px]">
            <div class="min-w-0">
              <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.nav_photos")}</h2>
              <p class="mt-[6px] text-[14px] text-ink-40">
                {#if status?.library_dir}
                  <!-- 设计稿 v2：照片页副标题 = 张数 + 「按原始文件存在 <库路径>」
                       （真实 library_dir，不写死路径） -->
                  {t("ui.photos_count_path", {
                    n: photoCount !== null ? photoCount : 0,
                    path: status.library_dir,
                  })}
                {:else}
                  {t("ui.photos_count", {
                    n: photoCount !== null ? photoCount : 0,
                    m: photoSources !== null ? photoSources : 0,
                  })}
                {/if}
              </p>
            </div>
            <!-- 设计稿 v2：lede 右侧「在 Finder 中打开」（openLibrary 揭示
                 originals/）；「刷新」是 DESK-06 的事件驱动失效兜底，保留。 -->
            <div class="flex flex-none items-center gap-[10px]">
              <Button variant="outline" class="{BTN_OUTLINE} mt-[2px] flex-none" onclick={openLibrary}>{t("ui.photos_open_library")}</Button>
              <Button variant="outline" class="{BTN_OUTLINE} mt-[2px] flex-none" onclick={resetPhotosWall}>
                {photosLoading ? "刷新中…" : "刷新"}
              </Button>
            </div>
          </div>
          <!-- 2026-08-17：DESK-08 迁 Tailwind 时把这张卡的 flex-1/min-h-0/
               overflow-y-auto 弄丢了，变回整个右侧内容区跟着长高再滚动
               （回归到 2026-08-13 已经修过一次的老问题）——照活动记录页
               同款处理补回来，照片格子在卡内自己滚，标题/工具栏不跟着走。 -->
          <Card class="min-h-0 flex-1 gap-0 overflow-y-auto rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
            {#if photosLoaded && photos.length === 0}
              <p class="m-0 text-[13px] leading-[1.6] text-ink-40">{t("ui.photos_empty")}</p>
            {:else if !photosLoaded}
              <p class="m-0 text-[13px] leading-[1.6] text-ink-40">正在加载照片…</p>
            {:else}
              {#each photoGroups as g (g.key)}
                <h4 class="mt-[14px] mb-[8px] text-[13px] font-semibold text-ink-60 first:mt-0">{g.label}</h4>
                <div class="grid grid-cols-[repeat(auto-fill,minmax(110px,1fr))] gap-[6px]">
                  {#each g.items as item (item.hash)}
                    <button
                      class="relative aspect-square cursor-zoom-in overflow-hidden rounded-sm border-0 border-none bg-border p-0 hover:outline-2 hover:outline-ink hover:outline-offset-2"
                      onclick={() => (photoViewer = item)}
                      aria-label="查看大图"
                    >
                      <PhotoThumb hash={item.hash} />
                      {#if item.media_type === "video"}
                        <span class="pointer-events-none absolute bottom-[5px] right-[5px] rounded-[4px] bg-black/55 px-[5px] py-[1px] text-[11px] text-white">▶</span>
                      {/if}
                    </button>
                  {/each}
                </div>
              {/each}
              {#if photosNext}
                <div class="h-6 text-center text-[12px] text-ink-60" bind:this={sentinelEl}>
                  {photosLoading ? "加载中…" : ""}
                </div>
              {/if}
            {/if}
          </Card>
          <p class="mt-[10px] text-[13px] leading-[1.6] text-ink-40">缩略图只用来快速翻找；整理、导出、删除都在 Finder 里进行——文件就是普通文件。</p>
        </section>
      {:else if page === "log"}
        <section class="page" data-testid="page-log">
          <!-- DESK-08: 活动记录页已迁 Tailwind + Card；审计流数据与过滤
               （ingest.* 噪音行剔除）一字未动。 -->
          <div class="flex flex-wrap items-end justify-between gap-[20px]">
            <div>
              <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">活动记录</h2>
              <p class="mt-[6px] text-[14px] text-ink-40">谁备份了什么，一目了然——不用去 Finder 里对账。</p>
            </div>
            <!-- 设计稿"本周"统计条：只做能从真实审计数据推出来的两项，
                 见上方 weekStats 注释——不编造「重试成功」这类没有真实
                 语义支撑的数字。 -->
            <div class="flex flex-none items-center gap-[18px] rounded-full bg-linen px-[22px] py-[10px] text-[14px] text-ink-60">
              <span class="text-[13px] font-semibold text-ink-40">本周</span>
              <span>新备份 <b class="text-ink">{weekStats.added}</b></span>
              <span>去重跳过 <b class="text-ink">{weekStats.dup}</b></span>
            </div>
          </div>
          <!-- T5: 活动记录页展示审计事件流——配对请求/允许/拒绝、备份会话
               （开始/结束+数量）、设备吊销/断开，全部带时间倒序。
               ingest.* 逐文件行过滤不展示（全路径噪音），备份完成行
               保留 ingested 汇总。2026-08-13: 改回设计稿的卡片行列表
               （DESK-05 当时改真表格的顾虑是"内容超长"，但 ingest.*
               噪音行本来就被过滤掉了，跟表格与否无关；卡片行是 flex
               布局，长文本本来就会自然换行，不会重新踩那个坑）。 -->
          <Card class="min-h-0 flex-1 gap-0 overflow-y-auto rounded-xl border border-border p-0 shadow-none ring-0 ring-transparent text-[16px]">
            {#if visibleAudit.length === 0}
              <p class="m-0 px-[22px] py-[18px] text-[13px] leading-[1.6] text-ink-40">这里还没有内容。配对、备份、移除设备的记录会按时间出现在这里。</p>
            {:else}
              <ul class="m-0 list-none p-0">
                {#each visibleAudit as e (e.ts + ":" + e.action)}
                  {@const at = humanTime(e.ts, nowMs)}
                  <li class="flex items-baseline gap-[14px] border-b border-divider px-[22px] py-[16px] last:border-b-0">
                    <span class="flex-1 text-[15px] text-ink"><b class="font-semibold">{auditWho(e)}</b> {auditText(e)}</span>
                    <span class="ml-auto flex-none whitespace-nowrap text-[13px] text-ink-40">{#if at}{at}{/if}</span>
                  </li>
                {/each}
              </ul>
            {/if}
          </Card>
          <p class="mt-[10px] text-[13px] leading-[1.6] text-ink-40">记录来自本机照片库与审计日志，不上传。</p>
        </section>
      {:else if page === "settings"}
        <section class="page" data-testid="page-settings">
          <!-- DESK-08: 设置页已迁 Tailwind + Card/Button；所有 IPC 调用与
               条件渲染（daemonStale 重启行/磁盘水位行）一字未动。 -->
          <div>
            <h2 class="m-0 font-serif text-[28px] font-normal leading-[1.3]">{t("ui.settings")}</h2>
          </div>
          <div class="flex items-start gap-[22px] max-[1079px]:flex-col">
            <Card class="flex-[1.2_1_0%] gap-0 rounded-xl border border-border px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
              <h3 class="mb-[12px] text-[15px] font-semibold">照片库</h3>
              {#if status?.library_dir}
                <code class="block rounded-sm bg-linen px-[16px] py-[12px] text-[14px] break-all">{status.library_dir}</code>
              {/if}
              <div class="mt-[12px] flex flex-wrap gap-[10px]">
                <Button class="{BTN}" onclick={openLibrary}>{t("ui.open_library")}</Button>
                <Button variant="outline" class="{BTN_OUTLINE}" onclick={chooseFolder}>{t("ui.change_library")}</Button>
              </div>
              <!-- T-092: 磁盘水位（status.disk_free_bytes/disk_total_bytes）——
                   「可用 X GB / 共 Y GB」+ 细进度条（token 色）；任一字段
                   null（磁盘统计拿不到）整行连进度条一起隐藏。 -->
              {#if diskFree !== null && diskTotal !== null && diskPct !== null}
                <div class="mt-[14px] flex justify-between gap-[12px] border-t border-divider pt-[14px] text-[14px] font-semibold">
                  <span>磁盘空间</span>
                  <span class="text-[14px] font-normal text-ink-40">可用 {diskFree} / 共 {diskTotal}</span>
                </div>
                <div class="mt-[10px] h-2 overflow-hidden rounded-full bg-hairline"><div class="h-full rounded-full bg-ink" style="width:{diskPct}%"></div></div>
              {/if}
              <p class="m-0 text-[13px] leading-[1.6] text-ink-40">更改位置重启后台服务后生效；已备份的照片不会自动搬家。</p>
            </Card>
            <div class="flex flex-1 flex-col gap-[22px]">
              <Card class="min-h-0 flex-1 gap-0 overflow-y-auto rounded-xl border border-border p-0 shadow-none ring-0 ring-transparent text-[16px]">
                <!-- DESK-02①: 更新通道零 UI——由构建推导（版本含 -test. →
                     test），旧 REL-02 通道选择行已删。 -->
                <div class="flex items-center justify-between gap-[12px] border-b border-divider px-[22px] py-[16px] text-[15px] font-medium last-of-type:border-b-0">
                  <span>软件更新</span>
                  <Button variant="outline" class="{BTN_OUTLINE}" onclick={() => checkForUpdate(true)}>检查更新</Button>
                </div>
                <!-- DAE-04: 桌面壳更新后 daemon 还是旧版（版本不一致）才
                     显示——一致时不出现，避免误杀正常运行的服务。 -->
                {#if daemonStale}
                  <div class="flex items-center justify-between gap-[12px] border-b border-divider px-[22px] py-[16px] text-[15px] font-medium last-of-type:border-b-0">
                    <span>{t("ui.restart_service")}</span>
                    <Button variant="outline" class="{BTN_OUTLINE}" onclick={restartDaemonProcess} disabled={restartingService}>
                      {restartingService ? t("ui.restarting_service") : t("ui.restart_service_btn")}
                    </Button>
                  </div>
                  <p class="m-0 px-[22px] py-[18px] text-[13px] leading-[1.6] text-ink-40">{t("ui.restart_service_hint")}</p>
                {/if}
                <div class="flex items-center justify-between gap-[12px] border-b border-divider px-[22px] py-[16px] text-[15px] font-medium last-of-type:border-b-0">
                  <span>遇到问题？导出诊断包</span>
                  <Button variant="outline" class="{BTN_OUTLINE}" onclick={exportLogs}>{t("ui.export_logs")}</Button>
                </div>
                <p class="m-0 px-[22px] py-[18px] text-[13px] leading-[1.6] text-ink-40">{t("ui.logs_hint")}</p>
              </Card>
              <Card class="gap-0 rounded-xl border border-act bg-act-bg px-[22px] py-5 shadow-none ring-0 ring-transparent text-[16px]">
                <h3 class="mb-[12px] text-[15px] font-semibold text-act">{t("ui.stop_service")}</h3>
                <p class="text-[13px] leading-[1.6] text-ink-40">{t("ui.stop_hint")}</p>
                <Button variant="outline" class="self-start {BTN_DANGER}" onclick={stopService}>{t("ui.stop_service")}</Button>
              </Card>
            </div>
          </div>
        </section>
      {/if}
    </main>
    <!-- T4 (H-10b): 配对状态机模态——二维码弹窗 + 允许/拒绝弹窗。 -->
    {#if showPairModal}
      <div class="modal-backdrop" onclick={closePairModal}>
        <div class="modal" onclick={(e) => e.stopPropagation()}>
          <!-- 设计稿 v2：弹窗标题「配对二维码 · 放大版」——亮码用途一目了然 -->
          <h3>配对二维码</h3>
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
            <!-- 设计稿离线版 v2：扫码有困难的退路——复制配对串手动传给
                 手机（比如隔空投送/微信发给家人自己粘）。 -->
            <button class="link-more safe" onclick={copyPairString}>无法扫码？复制配对串</button>
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
  /* DESK-08: 整个组件样式包进 @layer components——Tailwind v4 的
     utilities 层声明在 components 之后，工具类才能压过手写规则
     （Svelte 会把 button 等元素选择器加作用域类提升特异性，
     不包 layer 的话 44px min-height 这类基类永远赢）。 */
  @layer components {
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
  /* 展开态（≥1080px，跟设计稿交互原型一致）：不画图标，只显示文字。 */
  .nav-icon {
    display: none;
  }
  .nav-label {
    display: inline;
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
    /* 设计稿基准档（16 寸/1080-1439）内容区就是填满侧栏之外的可用宽度，
     * 不设人为上限——之前写死 880px，任何比 880+侧栏宽的窗口右边全是
     * 死区（用户实测反馈）。max-width 只在 ≥1440px 才需要（见文件尾
     * 的响应式媒体查询），防真的超宽屏内容无限拉伸。 */
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

  





  h3 {
    font-size: 15px;
    font-weight: 600;
    margin: 0 0 12px;
  }




  






  
  





  



  /* 2026-08-13：列表本身内部滚动，不是靠整个右边内容区变高再滚动
     （用户实测反馈：应该是表格内滚动，游标加载，不是整个右边区域
     滚动）。真正的游标分页（滚到底再补一批，而不是一次性 limit=100
     取全量）需要 activity.list 后端加 cursor 参数——现状后端只有
     limit，没有 before_ts/cursor，这部分先留白不假装做了，只把
     "列表内部滚动"这一半先落地。 */
  main[data-page="log"] .page,
  main[data-page="photos"] .page {
    height: 100%;
    box-sizing: border-box;
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
  /* 跟 .dev-name-btn/.dev-remove-btn 同族的极简文字链接——次要跳转
     不该是实心按钮，这条规则以后别的「看全部」链接也可以直接复用。 */
  .link-more {
    align-self: flex-start;
    font-size: 13.5px;
    font-weight: 600;
    color: var(--pp-ink-60);
    background: transparent;
    border: none;
    padding: 2px 0;
    cursor: pointer;
    min-height: 0;
    font-family: inherit;
  }
  .link-more:hover {
    color: var(--pp-ink);
    text-decoration: underline;
    text-underline-offset: 3px;
  }
  /* 设计稿离线版："一切正常还有 N 台"/"全部活动记录" 这类"一切都好，
     只是还有更多"的次要跳转用安全绿，不是中性灰——跟危险动作的红形成
     对照，颜色本身就是语义。 */
  .link-more.safe {
    color: var(--pp-safe);
  }
  .link-more.safe:hover {
    color: var(--pp-safe);
    text-decoration: underline;
    text-underline-offset: 3px;
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
    font-size: 13px;
    margin: 10px 0 0;
    line-height: 1.6;
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

  /* ============================================================
   * 三档响应式（离线版设计稿 v2「第 3 轮」），断点数值是设计稿原文。
   * 2026-08-13 二次修复：这几条媒体查询之前写在文件中段，被后面的
   * 无条件 .page/.cols 规则（同优先级、后出现）盖掉，等于白写——
   * CSS 层叠顺序下同优先级选择器谁在后面谁赢。媒体查询必须放在
   * 所有同选择器的无条件规则之后，这里统一挪到 <style> 最末尾。
   * ============================================================ */
  @media (max-width: 1079px) {
    .sidebar {
      width: 64px;
      padding: 14px 0;
      align-items: center;
    }
    .brand {
      display: none;
    }
    nav {
      align-items: center;
      gap: 4px;
    }
    .nav-item {
      width: 44px;
      height: 44px;
      padding: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      flex: none;
    }
    .nav-icon {
      display: block;
      color: var(--pp-ink-60);
    }
    .nav-item.active .nav-icon {
      color: var(--pp-paper);
    }
    .nav-label {
      display: none;
    }
    /* 服务状态缩成一个纯色点（设计稿原文），不再是文字胶囊。 */
    .service-pill {
      background: transparent !important;
      padding: 0;
      gap: 0;
    }
    .service-pill .dot {
      width: 12px;
      height: 12px;
    }
    .service-label {
      display: none;
    }
  }
  /* ≥1440：三栏，内容区居中不无限拉伸。总览卡片区（水位/添加设备/
     最近动静）改用 grid（见模板内联类），断点行为不靠这里的 @media，
     小屏单栏竖排是 grid-cols-1 默认值自然得到的，不需要额外规则。
     照片墙是缩略图网格不是读文字，没有"一行多少字读得舒服"的考量，
     豁免这条居中限宽，让墙铺满可用宽度（用户实测反馈：右边留白）。 */
  @media (min-width: 1440px) {
    .page {
      max-width: 1180px;
      /* 2026-08-13 二次走查：只限宽不居中 = 右侧死区（1920px 下实测
         486px）——"内容区居中不无限拉伸"要两个都做，margin auto 居中。 */
      margin: 0 auto;
    }
    main[data-page="photos"] .page {
      max-width: none;
    }

  }
  }
</style>
