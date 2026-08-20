//! WATCH-01: 本地目录监听——库目录（`originals/`）变化在秒级反映到索引。
//!
//! 事件风暴策略（2026-08-12 定稿，旧版 P-Pass-file-2024 思想平移）：
//! notify 监听 + 防抖（静默窗口 Reset）+ 父路径合并 + 增量扫描。
//! **事件只是触发器，扫描读取「当前真相」**——不依赖 watcher 事件的
//! 完备性，事件丢失/合并只会多扫一次，不会漏。
//!
//! 两条方向：
//! - 新增 → 增量扫描 + [`Ingestor::ingest`]（src_device = 本机 node_id，
//!   审计如实记本地导入；hash dedup 天然幂等——ingest 自产事件扫到
//!   已索引文件 = Duplicate 跳过）
//! - 删除 → 局部对账（[`Db::list_asset_paths_under`] +
//!   [`Reconcile::remove_asset`]，不逐事件删——ingest 移动文件产生的
//!   瞬态 remove 由防抖窗口吸收）
//!
//! 变化 → [`Throttle`] 合并 emit `timeline.invalidated`（批量一次）。
//! 每小时全量 reconcile 保留为兜底（监听丢事件时最终一致）。
//!
//! 监听根 = `library_root/originals`——`.ppf/`（staging/thumbs/blobs/
//! 索引）在树外，天然排除，不需要自产目录过滤。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::Semaphore;

use core_index::{IncomingFile, IngestOutcome, Ingestor};
use storage::Db;

use crate::events::{EventBus, Throttle, DEFAULT_THROTTLE_WINDOW};
use crate::Reconcile;

/// 防抖窗口：静默窗口模式——收到事件后开始计时，窗口内无新事件才处理。
/// 批量拖入 1000 张只触发一次扫描。
pub const DEFAULT_DEBOUNCE: Duration = Duration::from_millis(500);
/// ingest 并发上限（批量拖入时限制打爆）。
pub const DEFAULT_INGEST_CONCURRENCY: usize = 4;

/// 媒体扩展名白名单（只收照片/视频；`.DS_Store`、`Thumbs.db` 之类不 ingest）。
const MEDIA_EXTS: &[&str] = &[
    "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "bmp", //
    "mp4", "mov", "m4v", "avi", "mkv", "3gp", //
    "arw", "cr2", "nef", "dng",
];

/// 本地目录监听器。`Clone` 廉价（`Arc` 共享状态）——`spawn` 后句柄
/// 可丢弃，监听任务自己活着。
#[derive(Clone)]
pub struct LibraryWatcher {
    inner: Arc<WatcherInner>,
}

struct WatcherInner {
    db: Db,
    ingestor: Ingestor,
    reconcile: Reconcile,
    library_root: PathBuf,
    originals: PathBuf,
    /// 本机 node_id —— 本地导入文件的 src_device（审计 actor + 布局目录）。
    src_device: Vec<u8>,
    throttle: Option<Throttle>,
    debounce: Duration,
    ingest_concurrency: usize,
}

impl LibraryWatcher {
    /// `library_root` = daemon 数据目录（与 Reconcile/Ingestor 同根）；
    /// `node_id` = 本机身份（`transport::NodeId.0`）。
    pub fn new(
        db: Db,
        library_root: impl Into<PathBuf>,
        node_id: [u8; 32],
        events: EventBus,
    ) -> Self {
        let library_root = library_root.into();
        let reconcile = Reconcile::new(db.clone(), &library_root);
        // macOS: /var 是 /private/var 的符号链接，FSEvents 返回真实路径
        // （带 /private 前缀）而调用方可能给符号链接路径——不规范化的话
        // strip_prefix 全部失败，事件被 affected_dirs 过滤光。创建目录
        // 后 canonicalize 取真实路径作为监听根。
        let originals = library_root.join("originals");
        let originals = match std::fs::create_dir_all(&originals) {
            Ok(_) => originals.canonicalize().unwrap_or(originals),
            Err(_) => originals,
        };
        Self {
            inner: Arc::new(WatcherInner {
                ingestor: Ingestor::new(db.clone(), &library_root),
                db,
                reconcile,
                library_root: library_root.clone(),
                originals,
                src_device: node_id.to_vec(),
                throttle: Some(Throttle::new(events, DEFAULT_THROTTLE_WINDOW)),
                debounce: DEFAULT_DEBOUNCE,
                ingest_concurrency: DEFAULT_INGEST_CONCURRENCY,
            }),
        }
    }

    /// 测试用：覆盖防抖窗口（集成测试缩短等待）。
    pub fn with_debounce(mut self, d: Duration) -> Self {
        Arc::get_mut(&mut self.inner)
            .expect("no clones yet")
            .debounce = d;
        self
    }

    /// 启动监听（notify 事件 → 防抖 → 增量同步）。失败返回原因，调用方
    /// 降级为每小时 reconcile 兜底，不阻塞 daemon。
    pub fn spawn(&self) -> notify::Result<()> {
        let inner = self.inner.clone();
        std::fs::create_dir_all(&inner.originals).map_err(notify_err)?;

        // notify 回调跑在库内部线程——事件只转发，不处理。
        let (tx, rx) = std::sync::mpsc::channel::<Event>();
        let mut watcher: RecommendedWatcher =
            notify::recommended_watcher(move |res: notify::Result<Event>| {
                if let Ok(ev) = res {
                    // inotify 默认监听 Access（读访问）事件——本模块自己
                    // 的扫描/ingest 读文件会触发 Access → 触发扫描 → 又产生
                    // Access，无限事件循环（Linux 实测：ingest 后 Access 风暴
                    // 淹没 Remove 事件，删除永远不被发现）。只关心结构变化。
                    if matches!(ev.kind, notify::EventKind::Access(_)) {
                        return;
                    }
                    let _ = tx.send(ev);
                }
            })?;
        watcher.watch(&inner.originals, RecursiveMode::Recursive)?;

        // 保活：watcher drop 即停止监听——move 进线程 sleep 保活。
        std::thread::spawn(move || {
            let _keep_alive = watcher;
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        });

        // std mpsc → tokio mpsc 桥接（notify 线程不能碰 async）。
        let (tokio_tx, mut tokio_rx) = tokio::sync::mpsc::channel::<Event>(256);
        std::thread::spawn(move || {
            while let Ok(ev) = rx.recv() {
                if tokio_tx.blocking_send(ev).is_err() {
                    break;
                }
            }
        });

        // 防抖器 + 处理循环。
        let this = self.clone();
        tokio::spawn(async move {
            loop {
                // 等第一批事件（阻塞到有事件；channel 关闭 = 桥接线程死了，退出）。
                let Some(first) = tokio_rx.recv().await else {
                    tracing::warn!("WATCH-01: 事件桥接关闭，监听停止");
                    return;
                };
                let mut pending: HashSet<PathBuf> = first.paths.into_iter().collect();
                // 继续收，直到静默满 debounce——Reset 风格窗口。
                while let Ok(Some(ev)) = tokio::time::timeout(inner.debounce, tokio_rx.recv()).await
                {
                    pending.extend(ev.paths);
                }
                this.process(pending).await;
            }
        });
        Ok(())
    }

    /// 处理一批变化路径：过滤 → 父路径合并 → 增量扫描 ingest → 局部清理。
    async fn process(&self, paths: HashSet<PathBuf>) {
        let dirs = self.affected_dirs(paths);
        if dirs.is_empty() {
            return;
        }

        // 增量扫描（walk 是同步 IO，放 spawn_blocking）。
        let dirs_for_scan = dirs.clone();
        let files =
            match tokio::task::spawn_blocking(move || collect_media_files(&dirs_for_scan)).await {
                Ok(Ok(files)) => files,
                // ⚠️ WATCH-02：整棵目录被删时 read_dir 必然 ENOENT。这里
                // 早退会把「删除方向」一起跳掉——新增方向没东西可扫不等于
                // 这一批没变化。降级为空文件列表，继续跑局部对账。
                Ok(Err(e)) => {
                    tracing::debug!("WATCH-01: 扫描 {:?} 失败（目录可能已删）: {e}", dirs);
                    Vec::new()
                }
                Err(_) => return, // 任务被取消
            };

        let ingested = self.ingest_new(files).await;
        let removed = self.reconcile_under(&dirs).await;

        if ingested + removed > 0 {
            if let Some(t) = &self.inner.throttle {
                t.flush_now(); // 批次收尾——有挂起信号才发，绝不空发
            }
        }
    }

    /// 过滤 + 父路径合并：只保留 originals 树内、非隐藏、最顶层的变化目录。
    fn affected_dirs(&self, paths: HashSet<PathBuf>) -> Vec<PathBuf> {
        let originals = &self.inner.originals;
        let mut dirs: HashSet<PathBuf> = HashSet::new();
        for p in paths {
            let Ok(rel) = p.strip_prefix(originals) else {
                continue; // 树外（理论不会发生，监听根就是 originals）
            };
            if rel
                .components()
                .any(|c| c.as_os_str().to_str().is_some_and(|s| s.starts_with('.')))
            {
                continue; // 隐藏路径
            }
            let dir = if p.is_dir() {
                Some(p)
            } else {
                p.parent().map(|d| d.to_path_buf())
            };
            if let Some(d) = dir {
                if d.starts_with(originals) {
                    dirs.insert(d);
                }
            }
        }
        filter_parent_paths(dirs)
    }

    /// ingest 一批新文件，并发上限 [`DEFAULT_INGEST_CONCURRENCY`]。
    /// 返回真正入库（New）的数量；Duplicate/失败不计数。
    async fn ingest_new(&self, files: Vec<PathBuf>) -> usize {
        let sem = Arc::new(Semaphore::new(self.inner.ingest_concurrency));
        let mut set = tokio::task::JoinSet::new();
        for path in files {
            let permit = match sem.clone().acquire_owned().await {
                Ok(p) => p,
                Err(_) => break, // semaphore closed（不会发生）
            };
            let ingestor = self.inner.ingestor.clone();
            let src_device = self.inner.src_device.clone();
            set.spawn(async move {
                let _permit = permit;
                let name = path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let incoming = IncomingFile {
                    src_path: path.clone(),
                    file_name: name.clone(),
                    media_type: media_type_for(&name).to_string(),
                    src_device,
                };
                match ingestor.ingest(&incoming).await {
                    Ok(IngestOutcome::New(_)) => Some(()),
                    // 库内移动：索引已改指新位置，时间线要刷。
                    Ok(IngestOutcome::Moved(_)) => Some(()),
                    Ok(IngestOutcome::Duplicate) => None,
                    Err(e) => {
                        tracing::warn!("WATCH-01: ingest {:?} 失败: {e}", path);
                        None
                    }
                }
            });
        }
        let mut ingested = 0usize;
        while let Some(res) = set.join_next().await {
            if matches!(res, Ok(Some(_))) {
                ingested += 1;
                if let Some(t) = &self.inner.throttle {
                    t.signal(); // Throttle 合并窗口内的多次 signal
                }
            }
        }
        ingested
    }

    /// 局部对账（删除方向）：对变化目录枚举索引子树，磁盘缺失即清理。
    /// 复用 [`Reconcile::remove_asset`]（thumb 约定 + 审计口径只此一份）。
    async fn reconcile_under(&self, dirs: &[PathBuf]) -> usize {
        let mut removed = 0usize;
        for dir in dirs {
            let Ok(rel) = dir.strip_prefix(&self.inner.originals) else {
                continue;
            };
            // rel_path 以 "originals/" 开头（ingest place 的 rel 格式）。
            let prefix = format!("originals/{}", rel.to_string_lossy());
            let Ok(paths) = self.inner.db.list_asset_paths_under(&prefix).await else {
                continue; // 索引不可读——静默跳过，等下一轮/每小时兜底
            };
            // 性能口径：候选集 = 该子树下的索引行；变化目录是 originals
            // 本身时就是全库。每行一次 stat，成本线性且可预估（5 万行约
            // 百毫秒级），但必须整批下放 spawn_blocking——逐行同步 stat
            // 会把 async 运行时的工作线程钉住。
            let root = self.inner.library_root.clone();
            let missing = tokio::task::spawn_blocking(move || {
                paths
                    .into_iter()
                    .filter(|(_, rel_path)| !root.join(rel_path).exists())
                    .collect::<Vec<_>>()
            })
            .await
            .unwrap_or_default();

            for (hash, rel_path) in missing {
                if self
                    .inner
                    .reconcile
                    .remove_asset(&hash, &rel_path)
                    .await
                    .is_ok()
                {
                    removed += 1;
                    if let Some(t) = &self.inner.throttle {
                        t.signal();
                    }
                }
            }
        }
        removed
    }
}

/// 排序后只保留不是其他目录子目录的顶层目录（旧版 filterParentPaths）。
/// 排序保证父目录先于子目录出现（组件级比较，`originals/a` 不是
/// `originals/a-b` 的父——`Path::starts_with` 按组件匹配）。
fn filter_parent_paths(dirs: HashSet<PathBuf>) -> Vec<PathBuf> {
    let mut list: Vec<PathBuf> = dirs.into_iter().collect();
    list.sort();
    let mut result: Vec<PathBuf> = Vec::new();
    let mut prev: Option<PathBuf> = None;
    for d in list {
        let is_child = prev.as_ref().is_some_and(|p| d.starts_with(p));
        if !is_child {
            result.push(d.clone());
            prev = Some(d);
        }
    }
    result
}

/// 递归收集目录树里的媒体文件（隐藏文件/目录跳过）。
fn collect_media_files(dirs: &[PathBuf]) -> std::io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for dir in dirs {
        walk_media(dir, &mut out)?;
    }
    Ok(out)
}

fn walk_media(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        // ⚠️ WATCH-02：删除批次里目录本身就是刚消失的那个——「不在了」
        // 是这条路径的正常结果，不是错误。往上冒会让整批 process 早退，
        // 把删除方向的局部对账一起跳掉。
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in rd {
        let entry = match entry {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!("WATCH-01: read_dir 条目失败: {e}");
                continue;
            }
        };
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if name_str.starts_with('.') {
            continue;
        }
        let ft = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };
        if ft.is_dir() {
            walk_media(&entry.path(), out)?;
        } else if ft.is_file() && is_supported_media(&name_str) {
            out.push(entry.path());
        }
    }
    Ok(())
}

fn is_supported_media(name: &str) -> bool {
    MEDIA_EXTS.contains(&ext_of(name).as_str())
}

fn media_type_for(name: &str) -> &'static str {
    match ext_of(name).as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "heic" | "heif" => "image/heic",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "m4v" => "video/x-m4v",
        "avi" => "video/x-msvideo",
        "mkv" => "video/x-matroska",
        "3gp" => "video/3gpp",
        "arw" | "cr2" | "nef" | "dng" => "image/x-raw",
        _ => "application/octet-stream",
    }
}

fn ext_of(name: &str) -> String {
    name.rsplit('.').next().unwrap_or("").to_ascii_lowercase()
}

fn notify_err(e: std::io::Error) -> notify::Error {
    notify::Error::io(e)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scanning_a_vanished_dir_is_empty_not_an_error() {
        // WATCH-02：整棵目录被删时扫描必须返回空集而不是 Err——Err 会让
        // process 早退，删除方向的对账永远不跑。
        let missing = PathBuf::from("/nonexistent-ppass-watch02/originals/2026/08");
        let out = collect_media_files(&[missing]).expect("消失的目录不算错误");
        assert!(out.is_empty());
    }

    #[test]
    fn scanning_mixes_existing_and_vanished_dirs() {
        let tmp = std::env::temp_dir().join("ppass-watch02-probe");
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).unwrap();
        std::fs::write(tmp.join("IMG_1.jpg"), b"x").unwrap();
        let out = collect_media_files(&[tmp.clone(), tmp.join("gone")]).unwrap();
        assert_eq!(out.len(), 1, "存在的目录照扫，消失的跳过");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn filter_parents_keeps_only_top_level() {
        let set = HashSet::from([
            PathBuf::from("/originals/a/b/c"),
            PathBuf::from("/originals/a/b"),
            PathBuf::from("/originals/a"),
            PathBuf::from("/originals/x/y/z"),
            PathBuf::from("/originals/x"),
        ]);
        let out = filter_parent_paths(set);
        assert_eq!(
            out,
            vec![PathBuf::from("/originals/a"), PathBuf::from("/originals/x")]
        );
    }

    #[test]
    fn filter_parents_does_not_confuse_prefix_siblings() {
        // "a-b" 不是 "a" 的子目录——组件级比较必须区分。
        let set = HashSet::from([
            PathBuf::from("/originals/a"),
            PathBuf::from("/originals/a-b"),
        ]);
        let out = filter_parent_paths(set);
        assert_eq!(out.len(), 2, "前缀孪生目录必须各自保留");
    }

    #[test]
    fn filter_parents_single_dir() {
        let set = HashSet::from([PathBuf::from("/originals/ab12/2026/08")]);
        assert_eq!(filter_parent_paths(set).len(), 1);
    }

    #[test]
    fn media_whitelist_accepts_photos_and_videos() {
        assert!(is_supported_media("IMG_0001.jpg"));
        assert!(is_supported_media("IMG_0001.JPG")); // 大小写不敏感
        assert!(is_supported_media("VID_20260812.mp4"));
        assert!(is_supported_media("DSC_1234.HEIC"));
        assert!(is_supported_media("RAW_1.DNG"));
    }

    #[test]
    fn media_whitelist_rejects_junk_and_hidden() {
        assert!(!is_supported_media(".DS_Store"));
        assert!(!is_supported_media("Thumbs.db"));
        assert!(!is_supported_media("notes.txt"));
        assert!(!is_supported_media("archive.zip"));
        assert!(!is_supported_media("noext"));
    }

    #[test]
    fn media_type_maps_known_extensions() {
        assert_eq!(media_type_for("a.jpg"), "image/jpeg");
        assert_eq!(media_type_for("a.heic"), "image/heic");
        assert_eq!(media_type_for("a.mp4"), "video/mp4");
        assert_eq!(media_type_for("a.mov"), "video/quicktime");
        assert_eq!(media_type_for("a.dng"), "image/x-raw");
        assert_eq!(media_type_for("a.xyz"), "application/octet-stream");
    }
}
