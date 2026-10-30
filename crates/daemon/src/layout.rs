//! #1260：照片库盘上与本机上各放什么。
//!
//! 照片库那块盘只放照片和「传输时必须与照片同盘」的数据：`originals/`、库标记 `.ppf/`
//! （含 [`LIBRARY_ID_FILE`]）、两套 blob store 的数据 / 临时目录、各个 staging。服务自己的数据
//! ——索引、两个 blob store 的元数据库、缩略图——放本机，按库 ID 分目录
//! （`<本机数据目录>/libraries/<库 ID>/`）：空闲时服务不占库盘上任何文件，用户推出外接盘不再
//! 「磁盘正在使用」；换库位置时只要库 ID 不变，本机数据就跟着走（#639）。
//!
//! 标准做法：后台服务型软件（Syncthing、Immich、Lightroom 目录）都是「数据库在本机、媒体随便放」，
//! 媒体文件夹里只留一个标记。iroh-blobs 的 `FsStore::load_with_opts(db_path, Options)` 原生支持
//! 元数据库与数据分开放（数据与临时目录须同盘，正好都在库盘上）。

use std::io::Write as _;
use std::path::{Path, PathBuf};

use crate::library_location::LIBRARY_MARKER;

/// 库标记目录里的库 ID 文件（随机 128 位 hex，写一次永不改）。
pub const LIBRARY_ID_FILE: &str = "library-id";
/// 本机数据目录下按库 ID 分的子目录。
pub const LIBRARIES_DIR: &str = "libraries";
/// 本机记的「当前库 ID」——库盘上的 ID 与它不同 = 那里是别的库，不往里写。
pub const CURRENT_ID_FILE: &str = "current-library-id";

/// 库盘上的库 ID；没有（老库还没迁移、或不是 P-Pass 库）或读不出来 ⇒ `None`。
pub fn read_library_id(root: &Path) -> Option<String> {
    let text = std::fs::read_to_string(root.join(LIBRARY_MARKER).join(LIBRARY_ID_FILE)).ok()?;
    let id = text.trim();
    valid_id(id).then(|| id.to_string())
}

fn valid_id(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())
}

/// 库盘上没有库 ID 就生成一个（先写临时文件再改名，原子落盘）；有就原样返回。
pub fn ensure_library_id(root: &Path) -> std::io::Result<String> {
    if let Some(id) = read_library_id(root) {
        return Ok(id);
    }
    let mut raw = [0u8; 16];
    getrandom::fill(&mut raw).map_err(|e| std::io::Error::other(e.to_string()))?;
    let id: String = raw.iter().map(|b| format!("{b:02x}")).collect();
    write_atomically(
        &root.join(LIBRARY_MARKER).join(LIBRARY_ID_FILE),
        id.as_bytes(),
    )?;
    Ok(id)
}

/// 本机记的当前库 ID。
pub fn recorded_library_id(local_base: &Path) -> Option<String> {
    let text =
        std::fs::read_to_string(local_base.join(LIBRARIES_DIR).join(CURRENT_ID_FILE)).ok()?;
    let id = text.trim();
    valid_id(id).then(|| id.to_string())
}

/// 记下当前库 ID（换库位置 / 首次迁移时）。
pub fn record_library_id(local_base: &Path, id: &str) -> std::io::Result<()> {
    write_atomically(
        &local_base.join(LIBRARIES_DIR).join(CURRENT_ID_FILE),
        id.as_bytes(),
    )
}

/// 先写同目录临时文件、fsync，再改名。
pub(crate) fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        std::process::id()
    ));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

/// 库此刻在不在（启动判定与「重新检查」共用）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Presence {
    Present,
    /// 没有库标记：盘没接上、文件夹被移走 / 改名 / 删除。
    MarkerMissing,
    /// 有库标记，但库 ID 与本机记的不同：那里是别的库，不往里写。
    OtherLibrary {
        found: String,
        expected: String,
    },
}

/// 判据：库标记在，且库盘上的库 ID（有的话）等于本机记的（有的话）。老库还没有库 ID、或本机
/// 还没记过，都算在——迁移那一步会补上。
pub fn library_presence(root: &Path, local_base: &Path) -> Presence {
    if !crate::library_location::library_marker_present(root) {
        return Presence::MarkerMissing;
    }
    match (read_library_id(root), recorded_library_id(local_base)) {
        (Some(found), Some(expected)) if found != expected => {
            Presence::OtherLibrary { found, expected }
        }
        _ => Presence::Present,
    }
}

/// 一个库的各类文件落在哪。
#[derive(Debug, Clone)]
pub struct LibraryLayout {
    root: PathBuf,
    local: PathBuf,
    /// 迁移没能完成的这一次启动：照旧用库盘 `.ppf/` 里的老布局（下次启动重试迁移）。
    legacy: bool,
}

impl LibraryLayout {
    /// `root` = 照片库；`local_base` = 本机服务数据目录；`id` = 库 ID。
    pub fn new(root: &Path, local_base: &Path, id: &str) -> Self {
        Self {
            root: root.to_path_buf(),
            local: local_dir(local_base, id),
            legacy: false,
        }
    }

    /// 老布局（#1260 之前）：服务数据都在库盘 `.ppf/` 里。
    pub fn legacy(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
            local: root.join(LIBRARY_MARKER),
            legacy: true,
        }
    }

    pub fn is_legacy(&self) -> bool {
        self.legacy
    }

    /// 照片库根目录。
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// 本机上这个库的数据目录。
    pub fn local(&self) -> &Path {
        &self.local
    }

    /// 索引（本机）。
    pub fn index_db(&self) -> PathBuf {
        self.local.join("index.sqlite")
    }

    /// 缩略图根（本机）。
    pub fn thumbs(&self) -> PathBuf {
        self.local.join("thumbs")
    }

    /// 回退 blob store 的元数据库（本机）。
    pub fn blobs_db(&self) -> PathBuf {
        if self.legacy {
            return legacy::blobs_db(&self.root);
        }
        self.local.join("blobs.db")
    }

    /// 回退 blob store 的数据与临时目录（库盘）。
    pub fn blobs_data(&self) -> PathBuf {
        self.root.join(LIBRARY_MARKER).join("blobs")
    }

    /// Flow blob store 的元数据库（本机）。
    pub fn flow_blobs_db(&self) -> PathBuf {
        if self.legacy {
            return legacy::flow_blobs_db(&self.root);
        }
        self.local.join("flow-blobs.db")
    }

    /// Flow blob store 的数据与临时目录（库盘）。
    pub fn flow_blobs_data(&self) -> PathBuf {
        self.root.join(LIBRARY_MARKER).join("flow-blobs")
    }
}

/// `<local_base>/libraries/<id>`。
pub fn local_dir(local_base: &Path, id: &str) -> PathBuf {
    local_base.join(LIBRARIES_DIR).join(id)
}

/// 老布局（#1260 之前）在库盘 `.ppf/` 里的各个位置——只有迁移读它们。
pub mod legacy {
    use std::path::{Path, PathBuf};

    use crate::library_location::LIBRARY_MARKER;

    pub fn index_db(root: &Path) -> PathBuf {
        root.join(LIBRARY_MARKER).join("index.sqlite")
    }
    pub fn thumbs(root: &Path) -> PathBuf {
        root.join(LIBRARY_MARKER).join("thumbs")
    }
    pub fn blobs_db(root: &Path) -> PathBuf {
        root.join(LIBRARY_MARKER).join("blobs").join("blobs.db")
    }
    pub fn flow_blobs_db(root: &Path) -> PathBuf {
        root.join(LIBRARY_MARKER)
            .join("flow-blobs")
            .join("blobs.db")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn library() -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join(LIBRARY_MARKER)).unwrap();
        dir
    }

    #[test]
    fn library_id_is_written_once_and_kept() {
        let lib = library();
        assert_eq!(read_library_id(lib.path()), None);
        let id = ensure_library_id(lib.path()).unwrap();
        assert_eq!(id.len(), 32);
        assert_eq!(ensure_library_id(lib.path()).unwrap(), id, "写一次永不改");
        assert_eq!(read_library_id(lib.path()), Some(id));
    }

    // 库在不在：标记 + 库 ID 与本机记的一致。反证：不比库 ID ⇒ 第三段（别的库）判成在，红。
    #[test]
    fn presence_requires_the_marker_and_the_same_library_id() {
        let local = tempfile::tempdir().unwrap();
        let none = tempfile::tempdir().unwrap();
        assert_eq!(
            library_presence(&none.path().join("x"), local.path()),
            Presence::MarkerMissing
        );

        let lib = library();
        assert_eq!(
            library_presence(lib.path(), local.path()),
            Presence::Present,
            "老库还没有 ID"
        );
        let id = ensure_library_id(lib.path()).unwrap();
        record_library_id(local.path(), &id).unwrap();
        assert_eq!(
            library_presence(lib.path(), local.path()),
            Presence::Present
        );

        let other = library();
        let other_id = ensure_library_id(other.path()).unwrap();
        assert_eq!(
            library_presence(other.path(), local.path()),
            Presence::OtherLibrary {
                found: other_id,
                expected: id
            }
        );
    }

    // 老布局与迁移前完全同一组路径（迁移失败的那次启动照旧能开库）。
    #[test]
    fn the_legacy_layout_is_the_pre_1260_paths() {
        let root = Path::new("/Lib");
        let l = LibraryLayout::legacy(root);
        assert_eq!(l.index_db(), legacy::index_db(root));
        assert_eq!(l.thumbs(), legacy::thumbs(root));
        assert_eq!(l.blobs_db(), legacy::blobs_db(root));
        assert_eq!(l.flow_blobs_db(), legacy::flow_blobs_db(root));
        assert_eq!(l.blobs_data(), Path::new("/Lib/.ppf/blobs"));
    }

    #[test]
    fn service_data_is_local_and_transfer_data_stays_on_the_library() {
        let layout = LibraryLayout::new(Path::new("/Volumes/X/Lib"), Path::new("/L"), "ab");
        for local in [
            layout.index_db(),
            layout.thumbs(),
            layout.blobs_db(),
            layout.flow_blobs_db(),
        ] {
            assert!(local.starts_with("/L/libraries/ab"), "{local:?}");
        }
        for on_library in [layout.blobs_data(), layout.flow_blobs_data()] {
            assert!(
                on_library.starts_with("/Volumes/X/Lib/.ppf"),
                "{on_library:?}"
            );
        }
    }
}
