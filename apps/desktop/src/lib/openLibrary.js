// #1059：打开照片库 = 揭示磁盘上的目录，不依赖后台服务。
// 壳命令 `reveal_library` 只读解析路径（平台 config）并直接揭示，服务停止（IPC 不可达）
// 时照样可用。任何失败都落成 keyed 的 `ui.library_dir_unknown`，不透出
// IPC / 系统原文与路径。依赖注入，便于不起 Tauri 直接测。
export async function openLibraryDir({ reveal }) {
  // #1150：揭示哪条路径（`<库>/originals`，还没建则库根）由壳决定并执行，网页不经手路径。
  try {
    await reveal();
  } catch (e) {
    // 壳已给 keyed 错误就原样抛（errText 能翻）；其余一律归一。
    throw keyedOrUnknown(e);
  }
}

const UNKNOWN = () => ({ key: "ui.library_dir_unknown", params: {} });

function keyedOrUnknown(e) {
  if (e && typeof e === "object" && typeof e.key === "string") return e;
  if (typeof e === "string" && e.startsWith("{")) {
    try {
      const o = JSON.parse(e);
      if (o && typeof o.key === "string") return o;
    } catch (_) {}
  }
  return UNKNOWN();
}
