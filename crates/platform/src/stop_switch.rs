//! §5.1 / #1161：「用户希望服务运行吗」的开关文件（Windows 服务形态的 `wanted-state`）。
//!
//! 内容只有 `running` / `stopped`。daemon 开机自检读它，窗口程序在用户点停止 / 启动时写它，
//! 安装器失败恢复时也读它——三方认同一份（#1238：窗口程序不再另记一份「停过」标记）。
//! 纯文件读写、不依赖 Windows API，所以三平台都编译、都跑单测。

use std::path::Path;

use crate::{PlatformError, Result};

/// 读开关。`Ok(None)` = 文件不存在 / 读不出 / 内容不认识 —— 一律按「要运行」处理：
/// 宁可多起一次，也不要因为一个坏文件让服务永远起不来。
pub fn read_at(path: &Path) -> Option<bool> {
    let text = std::fs::read_to_string(path).ok()?;
    match text.trim() {
        "running" => Some(true),
        "stopped" => Some(false),
        _ => None,
    }
}

/// 写开关。给壳用。
///
/// #1167：文件已存在（安装器建好的那份）就**原地覆盖**。交互用户只对这一个文件有读写
/// 权，在私有目录里建临时文件（`FILE_ADD_FILE`）会被拒——以前的「临时文件 + 换名」在
/// 普通用户身份下必然失败，而调用方吞了错误，「停止后开机不再起」于是从没真正落盘。
/// 内容只有 7 个字节，截断后写入的窗口里读到空 / 半份都按「要运行」处理（见读的口径）。
pub fn write_at(path: &Path, running: bool) -> Result<()> {
    use std::io::Write as _;
    if path.is_file() {
        let body: &[u8] = if running { b"running" } else { b"stopped" };
        return std::fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(path)
            .and_then(|mut f| {
                f.write_all(body)?;
                f.sync_all()
            })
            .map_err(|e| PlatformError::Io {
                action: "write_wanted_state",
                source: e,
            });
    }
    let dir = path.parent().unwrap_or(path);
    std::fs::create_dir_all(dir).map_err(|e| PlatformError::Io {
        action: "create_wanted_state_dir",
        source: e,
    })?;
    let tmp = path.with_extension("tmp");
    let written = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(if running { b"running" } else { b"stopped" })?;
        f.sync_all()
    })();
    if let Err(e) = written {
        let _ = std::fs::remove_file(&tmp);
        return Err(PlatformError::Io {
            action: "write_wanted_state",
            source: e,
        });
    }
    std::fs::rename(&tmp, path).map_err(|e| PlatformError::Io {
        action: "replace_wanted_state",
        source: e,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// §5.1 / #1161：`wanted-state` 往返 + 坏内容一律按「要运行」处理（宁可多起一次，
    /// 不能让一个坏文件把服务永远关掉）。
    #[test]
    fn wanted_state_roundtrips_and_junk_means_running() {
        let d = tempfile::tempdir().expect("tempdir");
        let p = d.path().join("wanted-state");
        assert_eq!(read_at(&p), None, "不存在 = 不知道");
        write_at(&p, false).expect("write");
        assert_eq!(read_at(&p), Some(false));
        write_at(&p, true).expect("write");
        assert_eq!(read_at(&p), Some(true));
        std::fs::write(&p, "banana").expect("write junk");
        assert_eq!(read_at(&p), None, "坏内容 = 按运行");
        std::fs::write(&p, "  stopped\n").expect("write padded");
        assert_eq!(read_at(&p), Some(false), "容忍空白");
    }
}
