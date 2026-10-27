//! #1183：库残留统一清扫——**一张清单 + 一个入口**。
//!
//! ## 不变式
//!
//! 库目录里只该有两类文件：被索引 / 有效记录引用的，和正在进行的操作持有的。其余都是
//! 残留（来自崩溃、断电、出错路径或旧版本），不管来源，每次启动后与每小时巡检都清。
//! 这不是旧版本兼容逻辑，与版本无关。产品约束：库占盘 ≈ 照片本身（1x）。
//!
//! ## 清单
//!
//! [`ResidueKind::ALL`] 是 P-Pass 在库里写的全部临时 / 中间位置中、需要我们自己回收的那些；
//! 每一类「谁写 / 什么算引用 / 宽限 / 删除判据」登记在
//! `docs/desktop/business-rules.zh-CN.md` §5.7（`residue_kinds_are_registered_in_business_rules`
//! 双向核对）。不归这里管的两处也登记在那张表里：`.ppf/flow-blobs`（iroh 自己的周期 GC）、
//! `.ppf/blobs`（store 打开前在启动路径上 O(1) rename 进回收目录，见 `inbox::retire_blob_store`；
//! 回收目录本身是本清单的 `blobs-retired` 类）。
//!
//! ## 判据纪律（每一类都守）
//!
//! - 只认我们自己的命名（文件名严格匹配）；
//! - 只删普通文件：符号链接、目录不删也不跟进去，不递归删目录（唯一例外是 `blobs-retired`：
//!   整份都是我们挪过去的 iroh store，owner 2026-10-26 定为整目录删，仍不跟随链接）；
//! - 「正在进行的操作」必须能被认出来（活会话 / active grant / 名字里的 pid / 宽限期），
//!   认不出来就不删；
//! - 判定不了（查询失败、索引为空无法区分）就整类跳过、写日志；
//! - 日志只给计数、字节数、原因，不打路径 / 文件名（#1122 脱敏约定）。
//!
//! ## 何时跑
//!
//! 不在启动关键路径上：`main` 在启动就绪（IPC 已能查询、启动对账已完成）之后发信号，
//! [`ResidueSweeper::run_after`] 收到才跑第一轮；之后每小时巡检调 [`ResidueSweeper::run_once`]。
//! 两轮之间用一把锁串行，自己不会和自己并发。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use core_index::ResidueSweep;
use storage::Db;

use crate::inbox;

/// 新登记几类（缩略图临时文件、缩略图孤儿）的宽限：mtime 不足这么久的不删。
/// 只用在「新写出来的文件 mtime 一定是新的」那几类上（tempfile 新建、JPEG 新写）；
/// 复制出来的文件 mtime 可能是源文件的，不靠它，靠名字里的 pid（见 core-index）。
pub const RESIDUE_GRACE: Duration = Duration::from_secs(3600);

/// 清单：每一类一个 id（日志与文档里的名字）。顺序 = 执行顺序。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ResidueKind {
    /// `.ppf/blobs-retired-<pid>-<ns>/`：启动时挪走的回退 blob store（`inbox::retire_blob_store`）。
    BlobsRetired,
    /// `.ppf/staging/*.upload`：旧上传通道的半成品（#988 起没有写入方）。
    StagingPartial,
    /// `.ppf/staging/<hash>`：旧管线已校验、没有活会话认领的裸文件（MOB-32）。
    StagingOrphan,
    /// `.ppf/flow-staging/{node}-{seq}-{hash}`：Flow 导出中转文件（NET-20）。
    FlowStaging,
    /// `.ppf/supersede-staging/<hash>[-<pid>].part`：#851 拼接 B 的临时文件。
    SupersedeStaging,
    /// `.ppf/superseded/<hash>.<ext>`：#1182 之前留下的旧副本。
    Superseded,
    /// `originals/**/.ppf-ingest-<pid>-<ns>.part`：跨卷入库的临时副本（#1047）。
    IngestTemp,
    /// `.ppf/thumbs/<xx>/.thumb-XXXXXX`：缩略图原子写入的临时文件。
    ThumbTemp,
    /// `.ppf/thumbs/<xx>/<hash>.<size>.jpg`：索引里已经没有这个 hash 的缩略图。
    ThumbOrphan,
}

impl ResidueKind {
    pub const ALL: [ResidueKind; 9] = [
        ResidueKind::BlobsRetired,
        ResidueKind::StagingPartial,
        ResidueKind::StagingOrphan,
        ResidueKind::FlowStaging,
        ResidueKind::SupersedeStaging,
        ResidueKind::Superseded,
        ResidueKind::IngestTemp,
        ResidueKind::ThumbTemp,
        ResidueKind::ThumbOrphan,
    ];

    pub fn id(self) -> &'static str {
        match self {
            ResidueKind::BlobsRetired => "blobs-retired",
            ResidueKind::StagingPartial => "staging-partial",
            ResidueKind::StagingOrphan => "staging-orphan",
            ResidueKind::FlowStaging => "flow-staging",
            ResidueKind::SupersedeStaging => "supersede-staging",
            ResidueKind::Superseded => "superseded",
            ResidueKind::IngestTemp => "ingest-temp",
            ResidueKind::ThumbTemp => "thumb-temp",
            ResidueKind::ThumbOrphan => "thumb-orphan",
        }
    }
}

/// 一类的结果：清了多少，或为什么整类跳过（判定不了）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KindOutcome {
    Swept(ResidueSweep),
    Skipped(String),
}

/// 一轮清扫的结果，按清单顺序。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SweepSummary {
    pub outcomes: Vec<(ResidueKind, KindOutcome)>,
}

impl SweepSummary {
    pub fn get(&self, kind: ResidueKind) -> Option<&KindOutcome> {
        self.outcomes
            .iter()
            .find(|(k, _)| *k == kind)
            .map(|(_, o)| o)
    }

    pub fn freed_bytes(&self) -> u64 {
        self.outcomes
            .iter()
            .filter_map(|(_, o)| match o {
                KindOutcome::Swept(s) => Some(s.freed_bytes),
                KindOutcome::Skipped(_) => None,
            })
            .sum()
    }
}

/// 活会话声明过的 staging hash（`BackupEngine::staging_claims`）。
pub type StagingClaims = Arc<dyn Fn() -> HashSet<String> + Send + Sync>;

/// 统一入口。
#[derive(Clone)]
pub struct ResidueSweeper {
    db: Db,
    root: PathBuf,
    staging_claims: Option<StagingClaims>,
    grace: Duration,
    staging_grace: Duration,
    running: Arc<tokio::sync::Mutex<()>>,
}

impl ResidueSweeper {
    pub fn new(db: Db, library_root: impl Into<PathBuf>) -> Self {
        Self {
            db,
            root: library_root.into(),
            staging_claims: None,
            grace: RESIDUE_GRACE,
            staging_grace: crate::STAGING_ORPHAN_GRACE,
            running: Arc::default(),
        }
    }

    /// 旧管线 staging 孤儿的保护集来源。不接 ⇒ 认不出活会话 ⇒ `staging-orphan` 整类跳过。
    pub fn with_staging_claims(mut self, claims: StagingClaims) -> Self {
        self.staging_claims = Some(claims);
        self
    }

    /// 测试用：把所有宽限压到 `grace`（生产保持 [`RESIDUE_GRACE`] / `STAGING_ORPHAN_GRACE`）。
    pub fn with_grace_for_test(mut self, grace: Duration) -> Self {
        self.grace = grace;
        self.staging_grace = grace;
        self
    }

    /// 启动那一轮：等 `ready`（启动就绪）再跑。发送端被丢掉（daemon 在就绪前退出）就不跑。
    pub async fn run_after(
        self,
        ready: tokio::sync::oneshot::Receiver<()>,
    ) -> Option<SweepSummary> {
        if ready.await.is_err() {
            return None;
        }
        tracing::info!("#1183: 启动就绪，后台残留清扫开始");
        Some(self.run_once().await)
    }

    /// 按清单逐类跑一轮。某一类出错只影响它自己（记日志、整类跳过），不中断其余各类。
    pub async fn run_once(&self) -> SweepSummary {
        let _serial = self.running.lock().await;
        let mut summary = SweepSummary::default();
        for kind in ResidueKind::ALL {
            let outcome = self.sweep(kind).await;
            log_outcome(kind, &outcome);
            summary.outcomes.push((kind, outcome));
        }
        let freed = summary.freed_bytes();
        if freed > 0 {
            tracing::info!("#1183: 残留清扫完成，共释放 {freed} 字节");
        } else {
            tracing::debug!("#1183: 残留清扫完成，没有可清的");
        }
        summary
    }

    async fn sweep(&self, kind: ResidueKind) -> KindOutcome {
        let staging = self.root.join(".ppf/staging");
        match kind {
            ResidueKind::BlobsRetired => {
                let ppf = self.root.join(".ppf");
                let (removed, freed_bytes, kept) =
                    blocking(move || inbox::sweep_retired_blob_stores(&ppf)).await;
                KindOutcome::Swept(ResidueSweep {
                    removed,
                    freed_bytes,
                    kept: kept.into_iter().map(|r| ("-".to_string(), r)).collect(),
                    dir_removed: false,
                })
            }
            ResidueKind::StagingPartial => {
                let freed = blocking(move || inbox::sweep_partial_uploads(&staging)).await;
                bytes_only(freed)
            }
            ResidueKind::StagingOrphan => {
                let Some(claims) = &self.staging_claims else {
                    return KindOutcome::Skipped("no_session_source".into());
                };
                let protected = claims();
                let grace = self.staging_grace;
                let freed =
                    blocking(move || inbox::sweep_orphans(&staging, &protected, grace)).await;
                bytes_only(freed)
            }
            ResidueKind::FlowStaging => match self.db.active_flow_content_hashes().await {
                Ok(protected) => {
                    let dir = self.root.join(".ppf/flow-staging");
                    let grace = self.staging_grace;
                    let freed = blocking(move || {
                        inbox::sweep_flow_staging_orphans(&dir, &protected, grace)
                    })
                    .await;
                    bytes_only(freed)
                }
                // 保护集不可信时宁可漏收，不可误删。
                Err(_) => KindOutcome::Skipped("active_grants_query_failed".into()),
            },
            ResidueKind::SupersedeStaging => {
                from_index(core_index::sweep_supersede_staging(&self.db, &self.root).await)
            }
            ResidueKind::Superseded => {
                from_index(core_index::sweep_superseded_residue(&self.db, &self.root).await)
            }
            ResidueKind::IngestTemp => {
                from_index(core_index::sweep_ingest_residue(&self.db, &self.root).await)
            }
            ResidueKind::ThumbTemp => {
                let thumbs = self.root.join(".ppf/thumbs");
                let grace = self.grace;
                match blocking(move || list_thumbs(&thumbs)).await {
                    Ok(listing) => KindOutcome::Swept(
                        blocking(move || sweep_thumb_temps(&listing, grace)).await,
                    ),
                    Err(e) => KindOutcome::Skipped(format!("list_failed: {}", e.kind())),
                }
            }
            ResidueKind::ThumbOrphan => self.sweep_thumb_orphans().await,
        }
    }

    /// 缩略图孤儿：名字严格是 `<64 hex>.<THUMB_SIZES 之一>.jpg`、所在扇出目录 = hash 前两位、
    /// 索引里没有这个 hash、mtime 超过宽限；删之前逐个现查一次索引（防与新入库竞态）。
    /// 索引为空时整类跳过：分不清「库里真没照片」和「索引丢了正在重建」。
    async fn sweep_thumb_orphans(&self) -> KindOutcome {
        let indexed: HashSet<Vec<u8>> = match self.db.list_asset_paths().await {
            Ok(rows) => rows.into_iter().map(|(hash, _)| hash).collect(),
            Err(_) => return KindOutcome::Skipped("index_query_failed".into()),
        };
        if indexed.is_empty() {
            return KindOutcome::Skipped("index_empty".into());
        }
        let thumbs = self.root.join(".ppf/thumbs");
        let listing = match blocking(move || list_thumbs(&thumbs)).await {
            Ok(l) => l,
            Err(e) => return KindOutcome::Skipped(format!("list_failed: {}", e.kind())),
        };
        let mut out = ResidueSweep::default();
        for entry in listing.files {
            let Some(hash) = thumb_name_hash(&entry.dir, &entry.name) else {
                if !is_thumb_temp_name(&entry.name) {
                    out.kept.push(("-".into(), "unrecognized_name"));
                }
                continue;
            };
            if indexed.contains(hash.as_slice()) {
                continue; // 有引用：不是残留。
            }
            let tag = hex::encode(&hash[..4]);
            if !entry.is_file {
                out.kept.push((tag, "not_a_file"));
                continue;
            }
            if !aged(entry.age, self.grace) {
                out.kept.push((tag, "fresh"));
                continue;
            }
            match self.db.get_asset(&hash).await {
                Ok(None) => {}
                Ok(Some(_)) => continue, // 快照之后刚入库：有引用。
                Err(_) => {
                    out.kept.push((tag, "index_query_failed"));
                    continue;
                }
            }
            match std::fs::remove_file(&entry.path) {
                Ok(()) => {
                    out.removed += 1;
                    out.freed_bytes += entry.len;
                }
                Err(_) => out.kept.push((tag, "remove_failed")),
            }
        }
        out.kept.extend(listing.unrecognized);
        KindOutcome::Swept(out)
    }
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    // 清扫是维护动作：阻塞线程池拿不到（运行时正在关）就当什么都没做——这里不会 panic 传染。
    tokio::task::spawn_blocking(f)
        .await
        .expect("residue sweep blocking task panicked")
}

fn bytes_only(freed: u64) -> KindOutcome {
    KindOutcome::Swept(ResidueSweep {
        freed_bytes: freed,
        ..ResidueSweep::default()
    })
}

fn from_index(r: core_index::Result<ResidueSweep>) -> KindOutcome {
    match r {
        Ok(s) => KindOutcome::Swept(s),
        // 错误串可能带路径：日志里只留错误类别（#1122）。
        Err(e) => KindOutcome::Skipped(format!("index_error: {}", error_class(&e))),
    }
}

fn error_class(e: &core_index::IndexError) -> String {
    match e {
        core_index::IndexError::Io { source, .. } => format!("io {}", source.kind()),
        other => {
            let s = other.to_string();
            s.split(':').next().unwrap_or("error").to_owned()
        }
    }
}

fn log_outcome(kind: ResidueKind, outcome: &KindOutcome) {
    let id = kind.id();
    match outcome {
        KindOutcome::Skipped(reason) => {
            tracing::warn!("#1183: 残留 {id} 本轮跳过（判定不了，不删）：{reason}");
        }
        KindOutcome::Swept(s) => {
            if s.removed > 0 {
                tracing::info!(
                    "#1183: 残留 {id} 清掉 {} 个，释放 {} 字节",
                    s.removed,
                    s.freed_bytes
                );
            } else if s.freed_bytes > 0 {
                // staging 两类与 flow-staging 沿用的回收函数只报字节数（逐个文件另有日志）。
                tracing::info!("#1183: 残留 {id} 释放 {} 字节", s.freed_bytes);
            }
            // 没删的按原因计数；能认出是我们命名的才给指纹前 8 位（同一原因只举前 3 个）。
            let mut by_reason: std::collections::BTreeMap<&str, Vec<&str>> = Default::default();
            for (tag, reason) in &s.kept {
                by_reason.entry(reason).or_default().push(tag);
            }
            for (reason, tags) in by_reason {
                let sample: Vec<&str> =
                    tags.iter().copied().filter(|t| *t != "-").take(3).collect();
                tracing::info!(
                    "#1183: 残留 {id} 保留 {} 个（{reason}）{}",
                    tags.len(),
                    if sample.is_empty() {
                        String::new()
                    } else {
                        format!(" 例 {}…", sample.join("… "))
                    }
                );
            }
        }
    }
}

fn aged(age: Option<Duration>, grace: Duration) -> bool {
    // 读不出时间就别删——宁可漏收，不可误删。
    age.is_some_and(|a| a >= grace)
}

struct ThumbEntry {
    dir: String,
    name: String,
    path: PathBuf,
    is_file: bool,
    len: u64,
    age: Option<Duration>,
}

struct ThumbListing {
    files: Vec<ThumbEntry>,
    /// 扇出层不认识的东西（名字不是两位小写 hex、不是目录）：原因计数用。
    unrecognized: Vec<(String, &'static str)>,
}

/// 列 `.ppf/thumbs/<xx>/*`。根和扇出目录都只进真目录（不跟随符号链接）；不存在 = 空。
fn list_thumbs(root: &Path) -> std::io::Result<ThumbListing> {
    let mut out = ThumbListing {
        files: Vec::new(),
        unrecognized: Vec::new(),
    };
    match std::fs::symlink_metadata(root) {
        Ok(m) if m.is_dir() => {}
        Ok(_) => return Ok(out),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => return Err(e),
    }
    for fan in std::fs::read_dir(root)? {
        let fan = fan?;
        let dir = fan.file_name().to_string_lossy().into_owned();
        let is_fan_dir = fan.file_type()?.is_dir()
            && dir.len() == 2
            && dir.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
        if !is_fan_dir {
            out.unrecognized.push(("-".into(), "unrecognized_name"));
            continue;
        }
        for entry in std::fs::read_dir(fan.path())? {
            let entry = entry?;
            let kind = entry.file_type()?;
            // DirEntry::metadata 不跟随符号链接。
            let meta = entry.metadata().ok();
            out.files.push(ThumbEntry {
                dir: dir.clone(),
                name: entry.file_name().to_string_lossy().into_owned(),
                path: entry.path(),
                is_file: kind.is_file(),
                len: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                age: meta
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.elapsed().ok()),
            });
        }
    }
    Ok(out)
}

fn sweep_thumb_temps(listing: &ThumbListing, grace: Duration) -> ResidueSweep {
    let mut out = ResidueSweep::default();
    for entry in listing.files.iter().filter(|e| is_thumb_temp_name(&e.name)) {
        if !entry.is_file {
            out.kept.push(("-".into(), "not_a_file"));
            continue;
        }
        if !aged(entry.age, grace) {
            out.kept.push(("-".into(), "fresh"));
            continue;
        }
        match std::fs::remove_file(&entry.path) {
            Ok(()) => {
                out.removed += 1;
                out.freed_bytes += entry.len;
            }
            Err(_) => out.kept.push(("-".into(), "remove_failed")),
        }
    }
    out
}

/// `media_codec` 原子写缩略图的临时名：`tempfile` 的 `.thumb-` 前缀 + 6 个字母数字
/// （tempfile 默认随机长度），没有后缀。
const THUMB_TEMP_PREFIX: &str = ".thumb-";
const THUMB_TEMP_RAND_LEN: usize = 6;

fn is_thumb_temp_name(name: &str) -> bool {
    name.strip_prefix(THUMB_TEMP_PREFIX).is_some_and(|rand| {
        rand.len() == THUMB_TEMP_RAND_LEN && rand.bytes().all(|b| b.is_ascii_alphanumeric())
    })
}

/// `<64 位小写 hex>.<THUMB_SIZES 之一>.jpg` 且扇出目录 = hash 前两位 → hash；别的 `None`。
fn thumb_name_hash(dir: &str, name: &str) -> Option<[u8; 32]> {
    let stem = name.strip_suffix(".jpg")?;
    let (hex64, size) = stem.split_once('.')?;
    if !media_codec::THUMB_SIZES
        .iter()
        .any(|s| s.to_string() == size)
    {
        return None;
    }
    if hex64.len() != 64
        || !hex64
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
        || &hex64[..2] != dir
    {
        return None;
    }
    let mut out = [0u8; 32];
    hex::decode_to_slice(hex64, &mut out).ok()?;
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::SystemTime;

    const HOUR: Duration = Duration::from_secs(3600);

    struct Lib {
        _dir: tempfile::TempDir,
        root: PathBuf,
        db: Db,
    }

    async fn lib() -> Lib {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        fs::create_dir_all(root.join(".ppf")).unwrap();
        Lib {
            _dir: dir,
            root,
            db: Db::open_in_memory().await.unwrap(),
        }
    }

    fn write(path: &Path, bytes: &[u8]) -> PathBuf {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
        path.to_path_buf()
    }

    /// 把 mtime 往回拨 `by`（std 的 set_modified，跨平台）。
    fn age(path: &Path, by: Duration) {
        let f = fs::File::options().write(true).open(path).unwrap();
        f.set_modified(SystemTime::now() - by).unwrap();
    }

    fn asset(hash: [u8; 32], rel: &str) -> storage::Asset {
        storage::Asset {
            hash: hash.to_vec(),
            rel_path: rel.into(),
            media_type: "image/jpeg".into(),
            bytes: 1,
            taken_at: Some(0),
            width: None,
            height: None,
            src_device: vec![0xcc; 32],
            added_at: 0,
            thumb_state: 1,
        }
    }

    fn thumb(root: &Path, hash: &[u8; 32], size: u32) -> PathBuf {
        let hex = hex::encode(hash);
        root.join(".ppf/thumbs")
            .join(&hex[..2])
            .join(format!("{hex}.{size}.jpg"))
    }

    fn swept(s: &SweepSummary, kind: ResidueKind) -> ResidueSweep {
        match s.get(kind) {
            Some(KindOutcome::Swept(r)) => r.clone(),
            other => panic!("{}: {other:?}", kind.id()),
        }
    }

    // ── 清单登记 ──────────────────────────────────────────────

    /// 清单里每一类都必须登记在业务规则 §5.7 的表里（`` `id` `` 出现在表格行首列），
    /// 表里登记为本入口执行的行也都必须在清单里。
    /// 反证：从 `ALL` 删一类或在表里删一行 → 红。
    #[test]
    fn residue_kinds_are_registered_in_business_rules() {
        let doc = include_str!("../../../docs/desktop/business-rules.zh-CN.md");
        let start = doc.find("\n### 5.7 ").expect("业务规则缺 §5.7 库残留清扫");
        let section = &doc[start + 1..];
        let section = &section[..section[4..]
            .find("\n#")
            .map(|i| i + 4)
            .unwrap_or(section.len())];
        let doc_ids: HashSet<&str> = section
            .lines()
            .filter(|l| l.starts_with("| `"))
            .filter(|l| l.contains("ResidueSweeper"))
            .filter_map(|l| l.split('`').nth(1))
            .collect();
        let code_ids: HashSet<&str> = ResidueKind::ALL.iter().map(|k| k.id()).collect();
        assert_eq!(doc_ids, code_ids, "§5.7 清单 ↔ ResidueKind::ALL");
    }

    // ── 启动不在关键路径上 ───────────────────────────────────

    /// 启动那一轮只在「启动就绪」信号之后才动手；就绪之前残留原样在。
    /// 反证：`run_after` 不等 `ready` 直接跑 → 第一条断言红。
    #[tokio::test(flavor = "multi_thread")]
    async fn the_startup_round_waits_for_the_ready_signal() {
        let l = lib().await;
        let residue = write(&l.root.join(".ppf/staging/x.upload"), b"half");
        let (tx, rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(ResidueSweeper::new(l.db.clone(), &l.root).run_after(rx));
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(residue.exists(), "就绪之前不许动库");
        assert!(!task.is_finished());
        tx.send(()).unwrap();
        let summary = task.await.unwrap().expect("就绪后跑了一轮");
        assert!(!residue.exists(), "就绪之后清掉");
        assert_eq!(swept(&summary, ResidueKind::StagingPartial).freed_bytes, 4);
    }

    /// daemon 在就绪前退出（发送端被丢掉）：不跑。
    #[tokio::test(flavor = "multi_thread")]
    async fn no_ready_signal_means_no_sweep() {
        let l = lib().await;
        let residue = write(&l.root.join(".ppf/staging/x.upload"), b"half");
        let (tx, rx) = tokio::sync::oneshot::channel::<()>();
        drop(tx);
        assert!(ResidueSweeper::new(l.db.clone(), &l.root)
            .run_after(rx)
            .await
            .is_none());
        assert!(residue.exists());
    }

    // ── 迁移进统一入口的几类：经入口走一遍（判据细节见各自模块的单测） ─────────

    /// 旧管线 staging：半成品删；裸文件没主且过宽限删、有主的不删；没接会话来源 ⇒ 整类跳过。
    /// 反证：`StagingOrphan` 不查保护集 → `claimed` 被删，红。
    #[tokio::test(flavor = "multi_thread")]
    async fn staging_goes_through_the_entry_with_live_session_protection() {
        let l = lib().await;
        let staging = l.root.join(".ppf/staging");
        let partial = write(&staging.join("a.upload"), b"12");
        let orphan = write(&staging.join("orphan"), b"123");
        let claimed = write(&staging.join("claimed"), b"1234");
        age(&orphan, 2 * HOUR);
        age(&claimed, 2 * HOUR);

        let unwired = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        assert!(matches!(
            unwired.get(ResidueKind::StagingOrphan),
            Some(KindOutcome::Skipped(_))
        ));
        assert!(orphan.exists(), "认不出活会话就不删");
        assert!(!partial.exists());

        let claims: StagingClaims = Arc::new(|| ["claimed".to_string()].into_iter().collect());
        let s = ResidueSweeper::new(l.db.clone(), &l.root)
            .with_staging_claims(claims)
            .run_once()
            .await;
        assert_eq!(swept(&s, ResidueKind::StagingOrphan).freed_bytes, 3);
        assert!(!orphan.exists());
        assert!(claimed.exists(), "活会话声明过的不碰");
    }

    /// 未过宽限的 staging 裸文件不删（生产宽限 = STAGING_ORPHAN_GRACE，经入口不变）。
    /// 反证：入口里把 staging 的宽限换成 0 → 红。
    #[tokio::test(flavor = "multi_thread")]
    async fn fresh_staging_files_are_kept_by_the_entry() {
        let l = lib().await;
        let fresh = write(&l.root.join(".ppf/staging/fresh"), b"123");
        let fresh_flow = write(
            &l.root
                .join(".ppf/flow-staging")
                .join(format!("aa-1-{}", "22".repeat(32))),
            b"123",
        );
        let claims: StagingClaims = Arc::new(HashSet::new);
        ResidueSweeper::new(l.db.clone(), &l.root)
            .with_staging_claims(claims)
            .run_once()
            .await;
        assert!(fresh.exists() && fresh_flow.exists());
    }

    /// Flow staging：没有 active grant 认领、过宽限的删。
    /// 反证：`FlowStaging` 分支不跑 → 红。
    #[tokio::test(flavor = "multi_thread")]
    async fn flow_staging_goes_through_the_entry() {
        let l = lib().await;
        let orphan = write(
            &l.root
                .join(".ppf/flow-staging")
                .join(format!("aa-1-{}", "22".repeat(32))),
            b"12345",
        );
        age(&orphan, 2 * HOUR);
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        assert_eq!(swept(&s, ResidueKind::FlowStaging).freed_bytes, 5);
        assert!(!orphan.exists());
    }

    /// core-index 的三类经入口执行：supersede-staging、superseded、入库临时文件。
    /// 反证：入口里漏掉其中任何一类 → 对应断言红。
    #[tokio::test(flavor = "multi_thread")]
    async fn core_index_kinds_go_through_the_entry() {
        let l = lib().await;
        let other = std::process::id().wrapping_add(1);
        let staged = write(
            &l.root
                .join(core_index::SUPERSEDE_STAGING_DIR)
                .join(format!("{}-{other}.part", "11".repeat(32))),
            b"12",
        );
        let temp = write(
            &l.root
                .join(format!("originals/x/.ppf-ingest-{other}-1.part")),
            b"123",
        );
        // superseded：没有别名 ⇒ 不删（判据细节在 core-index 测试里），这里只验经入口跑到了。
        let superseded = write(
            &l.root
                .join(core_index::SUPERSEDED_RESIDUE_DIR)
                .join(format!("{}.jpg", "33".repeat(32))),
            b"1",
        );
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        assert_eq!(swept(&s, ResidueKind::SupersedeStaging).removed, 1);
        assert_eq!(swept(&s, ResidueKind::IngestTemp).removed, 1);
        assert_eq!(
            swept(&s, ResidueKind::Superseded).kept,
            vec![("33333333".to_string(), "no_alias")]
        );
        assert!(!staged.exists() && !temp.exists() && superseded.exists());
    }

    // ── 缩略图 ───────────────────────────────────────────────

    /// 索引里没有这个 hash、过了宽限的缩略图删；有索引行的不删。
    /// 反证：去掉「hash 在索引里」那条 → `kept` 的两张被删，红。
    #[tokio::test(flavor = "multi_thread")]
    async fn orphan_thumbs_are_removed_and_referenced_ones_kept() {
        let l = lib().await;
        let (live, gone) = ([0xa1; 32], [0xb2; 32]);
        l.db.insert_asset(&asset(live, "originals/a.jpg"))
            .await
            .unwrap();
        let kept: Vec<_> = media_codec::THUMB_SIZES
            .iter()
            .map(|s| write(&thumb(&l.root, &live, *s), b"live"))
            .collect();
        let orphans: Vec<_> = media_codec::THUMB_SIZES
            .iter()
            .map(|s| write(&thumb(&l.root, &gone, *s), b"orphan"))
            .collect();
        for p in kept.iter().chain(&orphans) {
            age(p, 2 * HOUR);
        }
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        let r = swept(&s, ResidueKind::ThumbOrphan);
        assert_eq!(r.removed, 2, "{r:?}");
        assert_eq!(r.freed_bytes, 12);
        assert!(kept.iter().all(|p| p.exists()));
        assert!(orphans.iter().all(|p| !p.exists()));
    }

    /// 刚写出来的（未过宽限）不删：可能是快照之后刚入库的那张。
    /// 反证：去掉宽限判断 → 红。
    #[tokio::test(flavor = "multi_thread")]
    async fn fresh_orphan_thumbs_are_kept() {
        let l = lib().await;
        l.db.insert_asset(&asset([0xa1; 32], "originals/a.jpg"))
            .await
            .unwrap();
        let fresh = write(&thumb(&l.root, &[0xb2; 32], 256), b"x");
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        assert_eq!(
            swept(&s, ResidueKind::ThumbOrphan).kept,
            vec![("b2b2b2b2".to_string(), "fresh")]
        );
        assert!(fresh.exists());
    }

    /// 索引为空：分不清「真没照片」和「索引丢了正在重建」，整类跳过。
    /// 反证：去掉 `index_empty` 判断 → 缩略图被删，红。
    #[tokio::test(flavor = "multi_thread")]
    async fn thumbs_are_left_alone_when_the_index_is_empty() {
        let l = lib().await;
        let t = write(&thumb(&l.root, &[0xb2; 32], 256), b"x");
        age(&t, 2 * HOUR);
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        assert_eq!(
            s.get(ResidueKind::ThumbOrphan),
            Some(&KindOutcome::Skipped("index_empty".into()))
        );
        assert!(t.exists());
    }

    /// 名字不是我们的命名（尺寸不对、扇出目录与 hash 不符、大写、别的扩展名、用户文件）、
    /// 不是普通文件（目录、链接）：一律不碰，日志不带名字。
    /// 反证：把扇出目录核对 `&hex64[..2] != dir` 去掉 → 放错目录的那张被删，红；
    /// 去掉 `is_file` 判断 → 链接被删，红。
    #[tokio::test(flavor = "multi_thread")]
    async fn thumb_lookalikes_dirs_and_links_are_kept() {
        let l = lib().await;
        l.db.insert_asset(&asset([0xa1; 32], "originals/a.jpg"))
            .await
            .unwrap();
        let hex = hex::encode([0xb2; 32]);
        let fan = l.root.join(".ppf/thumbs/b2");
        let mut keep = vec![
            write(&fan.join(format!("{hex}.512.jpg")), b"x"),
            write(&fan.join(format!("{hex}.256.png")), b"x"),
            write(&fan.join(format!("{}.256.jpg", hex.to_uppercase())), b"x"),
            write(&fan.join("IMG_0001.jpg"), b"x"),
            write(&fan.join(".thumb-abc"), b"x"),
            write(
                &l.root.join(".ppf/thumbs/c3").join(format!("{hex}.256.jpg")),
                b"x",
            ),
            write(
                &l.root.join(".ppf/thumbs/zz").join(format!("{hex}.256.jpg")),
                b"x",
            ),
        ];
        for p in &keep {
            age(p, 2 * HOUR);
        }
        let dir_named = fan.join(format!("{hex}.1024.jpg"));
        fs::create_dir_all(&dir_named).unwrap();
        let outside = l._dir.path().join("outside");
        fs::create_dir_all(&outside).unwrap();
        // 链接放进另一个分桶：大小写不敏感的文件系统（APFS 默认）上，`{hex}.256.jpg` 与上面那个
        // 大写名是同一个名字。
        let hex_b4 = hex::encode([0xb4; 32]);
        fs::create_dir_all(l.root.join(".ppf/thumbs/b4")).unwrap();
        for kind in platform::test_support::dir_link_kinds() {
            let link = l
                .root
                .join(".ppf/thumbs/b4")
                .join(format!("{hex_b4}.256.jpg"));
            if let Err(e) = kind.make(&outside, &link) {
                assert!(kind.may_need_privilege, "{}: {e}", kind.name);
                continue;
            }
            keep.push(link);
            break;
        }
        // 宽限压到 0：链接是刚建的（mtime 新），不压的话挡住它的是宽限而不是「只删普通文件」。
        let s = ResidueSweeper::new(l.db.clone(), &l.root)
            .with_grace_for_test(Duration::ZERO)
            .run_once()
            .await;
        assert_eq!(swept(&s, ResidueKind::ThumbOrphan).removed, 0);
        assert_eq!(swept(&s, ResidueKind::ThumbTemp).removed, 0);
        assert!(swept(&s, ResidueKind::ThumbOrphan)
            .kept
            .iter()
            .filter(|(_, r)| *r == "unrecognized_name")
            .all(|(t, _)| t == "-"));
        for p in &keep {
            assert!(fs::symlink_metadata(p).is_ok(), "不该被删：{}", p.display());
        }
        assert!(dir_named.is_dir());
    }

    /// 缩略图原子写入的临时文件（`.thumb-` + 6 位）：过宽限删，未过宽限不删。
    /// 反证：去掉宽限判断 → `fresh` 被删，红；把名字判据放宽成只看前缀 → `.thumb-abc` 被删
    /// （见上一条用例），红。
    #[tokio::test(flavor = "multi_thread")]
    async fn thumb_temp_files_are_removed_after_the_grace() {
        let l = lib().await;
        let fan = l.root.join(".ppf/thumbs/b2");
        let stale = write(&fan.join(".thumb-Ab3dE9"), b"half");
        let fresh = write(&fan.join(".thumb-Zz9yX8"), b"half");
        age(&stale, 2 * HOUR);
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        let r = swept(&s, ResidueKind::ThumbTemp);
        assert_eq!(r.removed, 1, "{r:?}");
        assert_eq!(r.kept, vec![("-".to_string(), "fresh")]);
        assert!(!stale.exists() && fresh.exists());
    }

    #[test]
    fn thumb_names_are_parsed_strictly() {
        let hex = hex::encode([0xb2; 32]);
        assert_eq!(
            thumb_name_hash("b2", &format!("{hex}.256.jpg")),
            Some([0xb2; 32])
        );
        assert_eq!(
            thumb_name_hash("b2", &format!("{hex}.1024.jpg")),
            Some([0xb2; 32])
        );
        assert_eq!(thumb_name_hash("c3", &format!("{hex}.256.jpg")), None);
        assert_eq!(thumb_name_hash("b2", &format!("{hex}.128.jpg")), None);
        assert_eq!(thumb_name_hash("b2", &format!("{hex}.jpg")), None);
        assert_eq!(
            thumb_name_hash("b2", &format!("{}.256.jpg", &hex[..62])),
            None
        );
        assert!(is_thumb_temp_name(".thumb-a1B2c3"));
        assert!(!is_thumb_temp_name(".thumb-a1B2c"));
        assert!(!is_thumb_temp_name(".thumb-a1B2c3.jpg"));
        assert!(!is_thumb_temp_name("thumb-a1B2c3"));
    }

    /// 启动时挪走的 blob store 经入口在后台删掉。
    /// 反证：从 `ALL` 拿掉 `BlobsRetired` → 回收目录还在，红。
    #[tokio::test(flavor = "multi_thread")]
    async fn retired_blob_stores_go_through_the_entry() {
        let l = lib().await;
        let blobs = l.root.join(".ppf/blobs");
        write(&blobs.join("store/data"), b"12345678");
        assert_eq!(
            inbox::retire_blob_store(&blobs),
            inbox::BlobStoreRetire::Retired
        );
        let s = ResidueSweeper::new(l.db.clone(), &l.root).run_once().await;
        let r = swept(&s, ResidueKind::BlobsRetired);
        assert_eq!((r.removed, r.freed_bytes), (1, 8), "{r:?}");
        let left: Vec<_> = fs::read_dir(l.root.join(".ppf"))
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert!(left.is_empty(), "{left:?}");
    }
}
