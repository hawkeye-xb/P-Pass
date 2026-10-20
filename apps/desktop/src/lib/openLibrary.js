// #1059：打开照片库 = 揭示磁盘上的目录，不依赖后台服务。
// 库目录由壳命令 `library_dir` 只读解析（平台 config），服务停止（IPC 不可达）
// 时照样取得到。任何失败都落成 keyed 的 `ui.library_dir_unknown`，不透出
// IPC / 系统原文与路径。依赖注入，便于不起 Tauri 直接测。
export async function openLibraryDir({ getDir, reveal }) {
  let dir;
  try {
    dir = await getDir();
  } catch (e) {
    // 壳已给 keyed 错误就原样抛（errText 能翻）；其余一律归一。
    throw keyedOrUnknown(e);
  }
  if (!dir) throw UNKNOWN();
  // originals/ 是照片所在；库刚建还没照片时打开库根目录。
  try {
    await reveal(`${dir}/originals`);
  } catch (_) {
    try {
      await reveal(dir);
    } catch (_2) {
      throw UNKNOWN();
    }
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
