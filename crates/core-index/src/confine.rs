//! #1150：读库内文件前先确认路径没有跑出库根。
//!
//! 索引里的 `rel_path` 来自库内数据库；库目录里也可能被同用户的其他进程放进符号链接。
//! 读原图 / 交出 blob / 生成缩略图之前，把「库根 + rel_path」解析成真实路径，
//! 必须仍在库根之内：`..`、绝对路径、指向库外的符号链接一律拒绝。

use std::path::{Component, Path, PathBuf};

/// 解析失败的原因。调用方一律当「找不到这个文件」处理，不向对端泄露路径。
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ConfineError {
    /// `rel_path` 本身就不是库内相对路径（绝对路径、`..`、盘符前缀）。
    #[error("rel_path is not a plain relative path")]
    NotRelative,
    /// 真实路径不在库根之内（符号链接越界）。
    #[error("resolved path leaves the library root")]
    Escapes,
    /// 库根或目标文件解析不出来（不存在、无权限）。
    #[error("cannot resolve path: {0}")]
    Unresolvable(String),
}

/// 把库内相对路径 `rel` 解析为真实绝对路径，保证它在 `library_root` 之内。
///
/// - 先按字面拒绝绝对路径与 `..`——`Path::join` 遇到绝对路径会**整个替换**库根；
/// - 库根与目标都 canonicalize：macOS 上 `/var` 是 `/private/var` 的符号链接，
///   只规范化一侧会让 `starts_with` 误判；
/// - 返回的是 canonical 路径，调用方应打开它，而不是原来拼出的路径。
pub fn resolve_in_library(library_root: &Path, rel: &str) -> Result<PathBuf, ConfineError> {
    let rel_path = Path::new(rel);
    if rel.is_empty()
        || !rel_path
            .components()
            .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
    {
        return Err(ConfineError::NotRelative);
    }
    let root = library_root
        .canonicalize()
        .map_err(|e| ConfineError::Unresolvable(format!("library root: {e}")))?;
    let resolved = root
        .join(rel_path)
        .canonicalize()
        .map_err(|e| ConfineError::Unresolvable(e.to_string()))?;
    if resolved.starts_with(&root) {
        Ok(resolved)
    } else {
        Err(ConfineError::Escapes)
    }
}

/// 同 [`resolve_in_library`]，但「文件根本不存在」不算违规：返回库根下的字面路径，
/// 让调用方照常走自己的「文件缺失」失败路径（缩略图生成失败要记账、进负缓存）。
/// 路径上有任何东西存在却解析不出来（指向库外或悬空的符号链接、无权限）仍然拒绝。
pub fn resolve_in_library_or_missing(
    library_root: &Path,
    rel: &str,
) -> Result<PathBuf, ConfineError> {
    match resolve_in_library(library_root, rel) {
        Err(ConfineError::Unresolvable(why)) => {
            // 库根自己不存在：同样没有任何东西可读，走调用方的「缺失」路径。
            let root = match library_root.canonicalize() {
                Ok(r) => r,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => library_root.to_path_buf(),
                Err(e) => return Err(ConfineError::Unresolvable(format!("library root: {e}"))),
            };
            let lexical = root.join(rel);
            match std::fs::symlink_metadata(&lexical) {
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    // 中间目录若是库外符号链接，canonicalize 会成功而非走到这里；
                    // 走到这里说明最终那一段不存在，且路径上没有解析不了的链接。
                    Ok(lexical)
                }
                _ => Err(ConfineError::Unresolvable(why)),
            }
        }
        other => other,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn lib() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("lib");
        fs::create_dir_all(root.join("originals/d")).unwrap();
        fs::write(root.join("originals/d/a.jpg"), b"x").unwrap();
        (dir, root)
    }

    #[test]
    fn a_plain_file_inside_the_library_resolves() {
        let (_g, root) = lib();
        let p = resolve_in_library(&root, "originals/d/a.jpg").unwrap();
        assert!(p.starts_with(root.canonicalize().unwrap()));
        assert_eq!(fs::read(p).unwrap(), b"x");
    }

    /// 反证：去掉字面检查，`..` 能走到库外的真实文件，这条红。
    #[test]
    fn dot_dot_and_absolute_paths_are_refused() {
        let (g, root) = lib();
        let outside = g.path().join("secret.txt");
        fs::write(&outside, b"s").unwrap();
        assert_eq!(
            resolve_in_library(&root, "../secret.txt"),
            Err(ConfineError::NotRelative)
        );
        assert_eq!(
            resolve_in_library(&root, "originals/../../secret.txt"),
            Err(ConfineError::NotRelative)
        );
        assert_eq!(
            resolve_in_library(&root, outside.to_str().unwrap()),
            Err(ConfineError::NotRelative),
            "绝对路径会让 join 替换库根"
        );
        assert_eq!(
            resolve_in_library(&root, ""),
            Err(ConfineError::NotRelative)
        );
    }

    /// 反证：去掉 canonicalize 后的 starts_with，库内符号链接指到库外就能读，这条红。
    #[cfg(unix)]
    #[test]
    fn a_symlink_pointing_outside_is_refused() {
        let (g, root) = lib();
        let outside = g.path().join("secret.txt");
        fs::write(&outside, b"s").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("originals/d/link.jpg")).unwrap();
        assert_eq!(
            resolve_in_library(&root, "originals/d/link.jpg"),
            Err(ConfineError::Escapes)
        );
        // 目录符号链接同理。
        std::os::unix::fs::symlink(g.path(), root.join("originals/up")).unwrap();
        assert_eq!(
            resolve_in_library(&root, "originals/up/secret.txt"),
            Err(ConfineError::Escapes)
        );
    }

    /// 库根自己是符号链接（用户把库放在别处再链过来）仍然可用。
    #[cfg(unix)]
    #[test]
    fn a_symlinked_library_root_still_works() {
        let (g, root) = lib();
        let link = g.path().join("root-link");
        std::os::unix::fs::symlink(&root, &link).unwrap();
        assert!(resolve_in_library(&link, "originals/d/a.jpg").is_ok());
    }

    #[test]
    fn a_missing_file_is_tolerated_only_by_the_missing_variant() {
        let (_g, root) = lib();
        let p = resolve_in_library_or_missing(&root, "originals/d/none.jpg").unwrap();
        assert!(p.starts_with(root.canonicalize().unwrap()) && !p.exists());
        assert_eq!(
            resolve_in_library_or_missing(&root, "../x.jpg"),
            Err(ConfineError::NotRelative)
        );
    }

    /// 悬空符号链接（指向库外不存在的目标）不算「不存在」。
    #[cfg(unix)]
    #[test]
    fn a_dangling_symlink_is_refused_even_by_the_missing_variant() {
        let (g, root) = lib();
        std::os::unix::fs::symlink(
            g.path().join("not-yet"),
            root.join("originals/d/dangle.jpg"),
        )
        .unwrap();
        assert!(resolve_in_library_or_missing(&root, "originals/d/dangle.jpg").is_err());
    }

    #[test]
    fn a_missing_file_is_unresolvable() {
        let (_g, root) = lib();
        assert!(matches!(
            resolve_in_library(&root, "originals/d/none.jpg"),
            Err(ConfineError::Unresolvable(_))
        ));
    }
}
