//! #1109：daemon 设备身份私钥的落定。
//!
//! 身份私钥派生 NodeId，已配对手机只认这个 NodeId（真机 P0：每次重启换 NodeId
//! 会把所有已配对手机变成孤儿）。存放处由平台决定（`platform::IdentityKeyHome`）：
//!
//! - **macOS**：data protection 钥匙串。数据目录里的旧明文 `.ppf/identity.key`
//!   不读、不迁移，身份落定后删除（不考虑旧版本，已配对手机重新配对）。
//! - **Windows / Linux**：维持现状，数据目录里的 `.ppf/identity.key`
//!   （unix 0600 / Windows 仅属主 DACL）。
//!
//! 判定对所有存放处一致：
//! - 读到 32 字节 → 用它。
//! - 确定没有 → 生成、写入、**读回比对一致**才用。
//! - 读失败、内容不合法、写失败、读回不一致 → `Err`，调用方拒绝启动。
//!   绝不回退明文、绝不悄悄换身份（旧实现读失败就生成新私钥覆盖原文件）。

use std::path::{Path, PathBuf};

use platform::{IdentityKeyHome, IdentityKeyStore, PlatformError};

/// 数据目录里的身份私钥文件（Windows / Linux 的存放处；macOS 上是要删的旧明文）。
pub const KEY_FILE: &str = ".ppf/identity.key";

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("读取身份私钥失败（{location}）：{source}")]
    Read {
        location: String,
        #[source]
        source: PlatformError,
    },
    #[error("身份私钥内容不合法（{location}）：{len} 字节，应为 32 字节")]
    Invalid { location: String, len: usize },
    #[error("生成身份私钥失败：{0}")]
    Mint(String),
    #[error("写入身份私钥失败（{location}）：{source}")]
    Write {
        location: String,
        #[source]
        source: PlatformError,
    },
    #[error("身份私钥写入后读回不一致（{location}）")]
    ReadBackMismatch { location: String },
    #[error("删除旧的明文身份私钥失败（{}）：{source}", path.display())]
    RetirePlaintext {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

/// 身份是读到的还是这次新生成的（只用于日志）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    Loaded,
    Minted,
}

/// 落定身份：读到就用；确定没有才生成、写入、读回比对。其余一律 `Err`。
pub fn settle(
    store: &dyn IdentityKeyStore,
    mint: impl FnOnce() -> anyhow::Result<[u8; 32]>,
) -> Result<([u8; 32], Origin), IdentityError> {
    let location = store.location();
    let read = |location: &str| {
        store.read().map_err(|source| IdentityError::Read {
            location: location.to_owned(),
            source,
        })
    };
    if let Some(bytes) = read(&location)? {
        let key = as_key(&bytes).ok_or(IdentityError::Invalid {
            location: location.clone(),
            len: bytes.len(),
        })?;
        return Ok((key, Origin::Loaded));
    }
    let key = mint().map_err(|e| IdentityError::Mint(e.to_string()))?;
    store.write(&key).map_err(|source| IdentityError::Write {
        location: location.clone(),
        source,
    })?;
    match read(&location)? {
        Some(back) if back == key => Ok((key, Origin::Minted)),
        _ => Err(IdentityError::ReadBackMismatch { location }),
    }
}

/// 系统安全存储：先落定身份，**之后**删数据目录里的旧明文私钥。落定失败时
/// 不动旧文件（拒绝启动，什么都不改）。删除失败同样拒绝启动：不留明文——
/// 已配对手机在重新配对前仍信任那把旧私钥。
pub fn settle_in_secure_store(
    store: &dyn IdentityKeyStore,
    data_dir: &Path,
    mint: impl FnOnce() -> anyhow::Result<[u8; 32]>,
) -> Result<([u8; 32], Origin), IdentityError> {
    let settled = settle(store, mint)?;
    let legacy = data_dir.join(KEY_FILE);
    match std::fs::remove_file(&legacy) {
        Ok(()) => tracing::info!("已删除旧的明文身份私钥: {}", legacy.display()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(source) => {
            return Err(IdentityError::RetirePlaintext {
                path: legacy,
                source,
            })
        }
    }
    Ok(settled)
}

/// daemon 这次运行用的身份。`ephemeral`（`--ephemeral` 测试 / 脚本模式）=
/// 只在内存里生成一把随机私钥：不读写存放处、不读写文件、不删旧明文。一次性
/// daemon 不需要稳定身份，随机 NodeId 也不在任何手机的白名单里；常驻服务
/// （LaunchAgent / 计划任务 / 壳的一次性拉起）都不带这个参数。
pub fn for_run(
    ephemeral: bool,
    home: IdentityKeyHome,
    data_dir: &Path,
    restrict: impl Fn(&Path) -> platform::Result<platform::Applied> + Send + Sync,
    mint: impl FnOnce() -> anyhow::Result<[u8; 32]>,
) -> Result<[u8; 32], IdentityError> {
    if ephemeral {
        let key = mint().map_err(|e| IdentityError::Mint(e.to_string()))?;
        tracing::info!("--ephemeral：使用只在内存里的临时身份，不读写身份私钥存放处");
        return Ok(key);
    }
    load_or_mint(home, data_dir, restrict, mint)
}

/// 按平台给的存放处落定身份。`restrict` 只用于数据目录文件（收紧到仅属主）。
pub fn load_or_mint(
    home: IdentityKeyHome,
    data_dir: &Path,
    restrict: impl Fn(&Path) -> platform::Result<platform::Applied> + Send + Sync,
    mint: impl FnOnce() -> anyhow::Result<[u8; 32]>,
) -> Result<[u8; 32], IdentityError> {
    let (key, origin, location) = match home {
        IdentityKeyHome::SecureStore(store) => {
            let (k, o) = settle_in_secure_store(store.as_ref(), data_dir, mint)?;
            (k, o, store.location())
        }
        IdentityKeyHome::DataDirFile => {
            let file = DataDirKeyFile {
                path: data_dir.join(KEY_FILE),
                restrict,
            };
            let (k, o) = settle(&file, mint)?;
            (k, o, file.location())
        }
    };
    if origin == Origin::Minted {
        // DEVLOG-03：只有位置、不含密钥内容，进日志是安全的。
        tracing::info!("身份密钥已铸造: {location}");
    }
    Ok(key)
}

fn as_key(bytes: &[u8]) -> Option<[u8; 32]> {
    bytes.try_into().ok()
}

/// Windows / Linux 的存放处：数据目录里的 `.ppf/identity.key`。
///
/// SEC-10 (#445)：读到和新写都要收紧权限——只在生成时收紧的话，SEC-07 之前
/// 生成的（或 DESK-24 搬目录带过来的）文件会一直保留继承来的 ACL。收紧失败
/// 不阻止启动，记一条 WARN；`Unsupported` 是「本平台没收紧」，不算失败。
struct DataDirKeyFile<R> {
    path: PathBuf,
    restrict: R,
}

impl<R> DataDirKeyFile<R>
where
    R: Fn(&Path) -> platform::Result<platform::Applied>,
{
    fn tighten(&self) {
        if let Err(e) = (self.restrict)(&self.path) {
            tracing::warn!("身份密钥权限收紧失败: {}: {e}", self.path.display());
        }
    }
}

impl<R> IdentityKeyStore for DataDirKeyFile<R>
where
    R: Fn(&Path) -> platform::Result<platform::Applied> + Send + Sync,
{
    fn read(&self) -> platform::Result<Option<Vec<u8>>> {
        match std::fs::read(&self.path) {
            Ok(bytes) => {
                // 幂等：已经收紧过的文件再收紧一次是空操作。
                self.tighten();
                Ok(Some(bytes))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(source) => Err(PlatformError::Io {
                action: "读取身份私钥文件",
                source,
            }),
        }
    }

    fn write(&self, secret: &[u8]) -> platform::Result<()> {
        let io = |source| PlatformError::Io {
            action: "写入身份私钥文件",
            source,
        };
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(io)?;
        }
        std::fs::write(&self.path, secret).map_err(io)?;
        self.tighten();
        Ok(())
    }

    fn location(&self) -> String {
        self.path.display().to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 内存里的存放处。`read_err` / `write_err` 模拟系统错误；`corrupt_on_write`
    /// 模拟写进去的和读回来的不一致。
    #[derive(Default)]
    struct MemStore {
        slot: Mutex<Option<Vec<u8>>>,
        read_err: bool,
        write_err: bool,
        corrupt_on_write: bool,
        writes: Mutex<u32>,
    }

    impl MemStore {
        fn holding(bytes: &[u8]) -> Self {
            Self {
                slot: Mutex::new(Some(bytes.to_vec())),
                ..Self::default()
            }
        }
        fn stored(&self) -> Option<Vec<u8>> {
            self.slot.lock().unwrap().clone()
        }
        fn writes(&self) -> u32 {
            *self.writes.lock().unwrap()
        }
    }

    impl IdentityKeyStore for MemStore {
        fn read(&self) -> platform::Result<Option<Vec<u8>>> {
            if self.read_err {
                return Err(PlatformError::Failed {
                    action: "读取钥匙串",
                    detail: "OSStatus -25308".into(),
                });
            }
            Ok(self.stored())
        }
        fn write(&self, secret: &[u8]) -> platform::Result<()> {
            *self.writes.lock().unwrap() += 1;
            if self.write_err {
                return Err(PlatformError::Failed {
                    action: "写入钥匙串",
                    detail: "OSStatus -34018".into(),
                });
            }
            let mut v = secret.to_vec();
            if self.corrupt_on_write {
                v[0] ^= 0xff;
            }
            *self.slot.lock().unwrap() = Some(v);
            Ok(())
        }
        fn location(&self) -> String {
            "内存".into()
        }
    }

    fn mint_7() -> anyhow::Result<[u8; 32]> {
        Ok([7u8; 32])
    }

    fn mint_must_not_run() -> anyhow::Result<[u8; 32]> {
        panic!("这条路径不许生成新私钥")
    }

    // ── 判定（存放处无关）────────────────────────────────────────

    /// 照常读取：已有私钥原样用，不生成、不写。
    /// 反证：把 settle 的「读到就返回」去掉（总是生成），这里变红。
    #[test]
    fn existing_key_is_loaded_not_reminted() {
        let store = MemStore::holding(&[3u8; 32]);
        let (k, o) = settle(&store, mint_must_not_run).unwrap();
        assert_eq!(k, [3u8; 32]);
        assert_eq!(o, Origin::Loaded);
        assert_eq!(store.writes(), 0);
    }

    /// 没有私钥：生成、写入、读回一致才用，存放处里留的就是返回的那把。
    /// 反证：把 settle 里的 `store.write` 去掉，读回为空 ⇒ 变红。
    #[test]
    fn missing_key_is_minted_written_and_read_back() {
        let store = MemStore::default();
        let (k, o) = settle(&store, mint_7).unwrap();
        assert_eq!(k, [7u8; 32]);
        assert_eq!(o, Origin::Minted);
        assert_eq!(store.stored().as_deref(), Some(&[7u8; 32][..]));
        assert_eq!(store.writes(), 1);
    }

    /// 读回不一致：拒绝（不把没真正落盘的身份拿去用）。
    /// 反证：把读回比对改成只要读到就放行，这里变红。
    #[test]
    fn read_back_mismatch_is_refused() {
        let store = MemStore {
            corrupt_on_write: true,
            ..MemStore::default()
        };
        let err = settle(&store, mint_7).unwrap_err();
        assert!(
            matches!(err, IdentityError::ReadBackMismatch { .. }),
            "{err}"
        );
    }

    /// 读失败（非「没有」）：拒绝启动，**不生成、不写**——旧实现在这里会生成
    /// 新私钥覆盖原条目，身份被静默替换。
    /// 反证：把 settle 的读改回 `if let Ok(Some(..))`（读失败当没有），这里
    /// 会走到 mint_must_not_run 而 panic ⇒ 变红。
    #[test]
    fn read_failure_refuses_without_minting() {
        let store = MemStore {
            read_err: true,
            ..MemStore::holding(&[3u8; 32])
        };
        let err = settle(&store, mint_must_not_run).unwrap_err();
        assert!(matches!(err, IdentityError::Read { .. }), "{err}");
        assert!(err.to_string().contains("-25308"), "原因要带出来：{err}");
        assert_eq!(store.writes(), 0);
    }

    /// 内容不合法（长度不是 32）：拒绝启动，不覆盖。
    /// 反证：把长度不对改成走生成分支（旧实现），这里 panic ⇒ 变红。
    #[test]
    fn invalid_length_refuses_without_overwriting() {
        let store = MemStore::holding(&[3u8; 31]);
        let err = settle(&store, mint_must_not_run).unwrap_err();
        assert!(
            matches!(err, IdentityError::Invalid { len: 31, .. }),
            "{err}"
        );
        assert_eq!(store.stored().as_deref(), Some(&[3u8; 31][..]));
    }

    /// 写失败：拒绝启动。
    /// 反证：把 `store.write(..)?` 的错误吞掉，读回为空 ⇒ 报的是读回不一致，
    /// 本条对 Write 变体的断言变红。
    #[test]
    fn write_failure_refuses() {
        let store = MemStore {
            write_err: true,
            ..MemStore::default()
        };
        let err = settle(&store, mint_7).unwrap_err();
        assert!(matches!(err, IdentityError::Write { .. }), "{err}");
    }

    // ── 系统安全存储：旧明文删除 ────────────────────────────────

    fn legacy_file(dir: &Path) -> PathBuf {
        let f = dir.join(KEY_FILE);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(&f, [9u8; 32]).unwrap();
        f
    }

    /// 身份落定后删除旧明文；旧明文**不被读**（钥匙串里没有时生成的是新私钥，
    /// 不是旧文件里那把）。
    /// 反证：去掉 settle_in_secure_store 的 remove_file，文件仍在 ⇒ 变红；
    /// 改成「钥匙串没有就读旧文件迁移」，k 会是 [9;32] ⇒ 变红。
    #[test]
    fn legacy_plaintext_is_removed_and_never_read() {
        let dir = tempfile::tempdir().unwrap();
        let f = legacy_file(dir.path());
        let store = MemStore::default();
        let (k, _) = settle_in_secure_store(&store, dir.path(), mint_7).unwrap();
        assert_eq!(k, [7u8; 32], "不许迁移旧明文私钥");
        assert!(!f.exists(), "旧明文私钥必须删掉");
    }

    /// 钥匙串里已有私钥的每次启动也删（不只在生成那次）。
    /// 反证：只在 Origin::Minted 时删，这里变红。
    #[test]
    fn legacy_plaintext_is_removed_on_ordinary_load_too() {
        let dir = tempfile::tempdir().unwrap();
        let f = legacy_file(dir.path());
        let store = MemStore::holding(&[3u8; 32]);
        let (k, _) = settle_in_secure_store(&store, dir.path(), mint_must_not_run).unwrap();
        assert_eq!(k, [3u8; 32]);
        assert!(!f.exists());
    }

    /// 身份没落定（拒绝启动）时不动旧文件：删除排在落定之后。
    /// 反证：把 remove_file 挪到 settle 之前，这里变红。
    #[test]
    fn legacy_plaintext_is_kept_when_identity_fails() {
        let dir = tempfile::tempdir().unwrap();
        let f = legacy_file(dir.path());
        let store = MemStore {
            read_err: true,
            ..MemStore::default()
        };
        settle_in_secure_store(&store, dir.path(), mint_must_not_run).unwrap_err();
        assert!(f.exists());
    }

    /// 没有旧文件是常态，不是错误。
    #[test]
    fn no_legacy_plaintext_is_fine() {
        let dir = tempfile::tempdir().unwrap();
        let store = MemStore::holding(&[3u8; 32]);
        assert!(settle_in_secure_store(&store, dir.path(), mint_must_not_run).is_ok());
    }

    /// 旧明文删不掉（这里用同名目录造出非 NotFound 的错误）：拒绝启动。
    /// 反证：把删除错误降级成 WARN 继续，这里变红。
    #[test]
    fn legacy_plaintext_removal_failure_refuses() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(KEY_FILE)).unwrap();
        let store = MemStore::holding(&[3u8; 32]);
        let err = settle_in_secure_store(&store, dir.path(), mint_must_not_run).unwrap_err();
        assert!(
            matches!(err, IdentityError::RetirePlaintext { .. }),
            "{err}"
        );
    }

    // ── --ephemeral：内存里的临时身份 ─────────────────────────────

    /// 只数调用次数的存放处：任何一次 read / write / location 都记一笔。
    struct CountingStore(std::sync::Arc<std::sync::atomic::AtomicU32>);

    impl IdentityKeyStore for CountingStore {
        fn read(&self) -> platform::Result<Option<Vec<u8>>> {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(Some(vec![3u8; 32]))
        }
        fn write(&self, _: &[u8]) -> platform::Result<()> {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(())
        }
        fn location(&self) -> String {
            self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            "计数".into()
        }
    }

    /// `--ephemeral`：钥匙串端口一次都不被调用，用的是现生成的随机私钥，
    /// 旧明文文件原样不动。
    /// 反证：把 for_run 的 `if ephemeral` 分支去掉（照常走存放处），计数变成
    /// 非 0、返回 [3;32]、旧文件被删 ⇒ 变红。
    #[test]
    fn ephemeral_never_touches_the_key_store() {
        let dir = tempfile::tempdir().unwrap();
        let f = legacy_file(dir.path());
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let k = for_run(
            true,
            IdentityKeyHome::SecureStore(Box::new(CountingStore(calls.clone()))),
            dir.path(),
            |_| panic!("--ephemeral 不该碰文件权限"),
            mint_7,
        )
        .unwrap();
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 0);
        assert_eq!(k, [7u8; 32]);
        assert!(f.exists(), "--ephemeral 不删旧明文");
    }

    /// 非 ephemeral 照常走存放处（计数实现本身有判别力）。
    #[test]
    fn non_ephemeral_uses_the_key_store() {
        let dir = tempfile::tempdir().unwrap();
        let calls = std::sync::Arc::new(std::sync::atomic::AtomicU32::new(0));
        let k = for_run(
            false,
            IdentityKeyHome::SecureStore(Box::new(CountingStore(calls.clone()))),
            dir.path(),
            |_| Ok(platform::Applied::Done),
            mint_must_not_run,
        )
        .unwrap();
        assert!(calls.load(std::sync::atomic::Ordering::SeqCst) > 0);
        assert_eq!(k, [3u8; 32]);
    }

    // ── 数据目录文件（Windows / Linux 现状）──────────────────────

    fn recording(
        calls: &Mutex<Vec<PathBuf>>,
    ) -> impl Fn(&Path) -> platform::Result<platform::Applied> + Send + Sync + '_ {
        move |p| {
            calls.lock().unwrap().push(p.to_path_buf());
            Ok(platform::Applied::Done)
        }
    }

    // SEC-10 (#445)：已有的私钥读取时也要收紧，且不重新生成。
    #[test]
    fn sec10_existing_identity_is_tightened_and_kept() {
        let dir = tempfile::tempdir().unwrap();
        let key_file = legacy_file(dir.path());
        let calls = Mutex::new(Vec::new());
        let k = load_or_mint(
            IdentityKeyHome::DataDirFile,
            dir.path(),
            recording(&calls),
            mint_must_not_run,
        )
        .unwrap();
        assert_eq!(
            k, [9u8; 32],
            "an existing key must be loaded, not re-minted"
        );
        assert_eq!(*calls.lock().unwrap(), vec![key_file]);
    }

    #[test]
    fn sec10_minted_identity_is_tightened() {
        let dir = tempfile::tempdir().unwrap();
        let calls = Mutex::new(Vec::new());
        let k = load_or_mint(
            IdentityKeyHome::DataDirFile,
            dir.path(),
            recording(&calls),
            mint_7,
        )
        .unwrap();
        let key_file = dir.path().join(KEY_FILE);
        assert_eq!(std::fs::read(&key_file).unwrap(), k);
        // 写入时收紧一次，读回时再收紧一次（幂等）。
        assert_eq!(*calls.lock().unwrap(), vec![key_file.clone(), key_file]);
    }

    #[test]
    fn sec10_tighten_failure_does_not_block_startup() {
        let dir = tempfile::tempdir().unwrap();
        legacy_file(dir.path());
        let k = load_or_mint(
            IdentityKeyHome::DataDirFile,
            dir.path(),
            |_| {
                Err(PlatformError::Failed {
                    action: "restrict_to_owner",
                    detail: "denied".into(),
                })
            },
            mint_must_not_run,
        )
        .unwrap();
        assert_eq!(k, [9u8; 32]);
    }

    /// 数据目录文件读失败（这里用同名目录造出非 NotFound 的错误）：拒绝启动，
    /// 不覆盖——旧实现 `if let Ok(..) = read` 会生成新私钥并试图写过去。
    /// 反证：DataDirKeyFile::read 把所有错误都当 `Ok(None)`，这里 panic ⇒ 变红。
    #[test]
    fn data_dir_file_read_failure_refuses() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(KEY_FILE)).unwrap();
        let err = load_or_mint(
            IdentityKeyHome::DataDirFile,
            dir.path(),
            |_| Ok(platform::Applied::Done),
            mint_must_not_run,
        )
        .unwrap_err();
        assert!(matches!(err, IdentityError::Read { .. }), "{err}");
    }

    /// 数据目录文件长度不对：拒绝启动，原文件不动。
    #[test]
    fn data_dir_file_invalid_length_refuses_and_keeps_file() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join(KEY_FILE);
        std::fs::create_dir_all(f.parent().unwrap()).unwrap();
        std::fs::write(&f, [1u8; 16]).unwrap();
        let err = load_or_mint(
            IdentityKeyHome::DataDirFile,
            dir.path(),
            |_| Ok(platform::Applied::Done),
            mint_must_not_run,
        )
        .unwrap_err();
        assert!(
            matches!(err, IdentityError::Invalid { len: 16, .. }),
            "{err}"
        );
        assert_eq!(std::fs::read(&f).unwrap(), [1u8; 16]);
    }

    /// 系统安全存储分支经 load_or_mint 也删旧明文（接线没漏）。
    #[test]
    fn secure_store_home_removes_legacy_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let f = legacy_file(dir.path());
        let k = load_or_mint(
            IdentityKeyHome::SecureStore(Box::new(MemStore::default())),
            dir.path(),
            |_| panic!("系统安全存储不该碰文件权限"),
            mint_7,
        )
        .unwrap();
        assert_eq!(k, [7u8; 32]);
        assert!(!f.exists());
    }
}
