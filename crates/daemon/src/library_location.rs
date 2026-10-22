//! #1115：照片库位置——安全相关配置，只认本应用签名程序写入的值。
//!
//! 库位置决定 daemon 拿什么目录、用真身份对外服务。config.toml 同一用户谁都能改，所以：
//! - **正本**：有平台安全存储时（macOS 钥匙串，只有带访问组授权的签名 daemon 读写得了）
//!   正本在那里，config.toml 里的 `data_dir` 只给人看、daemon 不认；没有安全存储的平台
//!   （Windows / Linux）正本仍是 config.toml。
//! - **唯一写者**：[`LibraryLocation::set`]，只经 IPC 方法 `config.set_library` 调到，且
//!   只对验过签名的窗口程序开放（`ipc.rs`）。以前的 CLI 子命令 `config init` /
//!   `config set-library` 已删除：签名的 daemon 谁都能带参数运行，CLI 写入口等于谁都能改。
//! - **未配置**：正本里还没有库位置 ⇒ daemon 进入「未配置」状态（只答 `status` 与
//!   `config.set_library`，不开库、不起传输），由窗口程序的首启向导完成配置。

use std::path::{Path, PathBuf};

use crate::config::{self, Config, CONFIG_FILE_NAME};

/// 常驻 daemon 这次启动的库。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResidentLibrary {
    /// 已配置：用这个目录。`configured` = 来自显式配置（不存在就拒绝启动，DESK-46）。
    At { dir: PathBuf, configured: bool },
    /// 正本里还没有库位置。
    Unconfigured,
}

pub struct LibraryLocation {
    store: Option<Box<dyn platform::SecretBlobStore>>,
    platform_dir: PathBuf,
}

impl LibraryLocation {
    /// 本平台的库位置（正本由平台决定）。
    pub fn for_platform() -> Self {
        use platform::PlatformAdapter as _;
        let adapter = platform::adapter();
        Self {
            store: adapter.library_store(),
            platform_dir: adapter.data_dir(),
        }
    }

    /// 测试用：指定正本与平台目录。
    pub fn with(store: Option<Box<dyn platform::SecretBlobStore>>, platform_dir: PathBuf) -> Self {
        Self {
            store,
            platform_dir,
        }
    }

    pub fn platform_dir(&self) -> &Path {
        &self.platform_dir
    }

    /// 常驻 daemon 的库。有安全存储时只看正本（config.toml 的 `data_dir` 不作数）；读不出来
    /// ⇒ `Err`，调用方拒绝启动（不回退到 config.toml）。没有安全存储时沿用 config 的语义。
    pub fn resident_library(&self, config: &Config) -> Result<ResidentLibrary, String> {
        match &self.store {
            Some(store) => match store.read().map_err(|e| e.to_string())? {
                None => Ok(ResidentLibrary::Unconfigured),
                Some(bytes) => {
                    let dir = String::from_utf8(bytes)
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| format!("{} 里的库位置读不懂", store.location()))?;
                    if config::configured_library_dir(&self.platform_dir).as_deref()
                        != Some(dir.as_str())
                    {
                        tracing::warn!(
                            "#1115: config.toml 的 data_dir 与正本不一致——以正本为准（{dir}）"
                        );
                    }
                    Ok(ResidentLibrary::At {
                        dir: PathBuf::from(dir),
                        configured: true,
                    })
                }
            },
            None => Ok(match &config.data_dir {
                Some(dir) => ResidentLibrary::At {
                    dir: dir.clone(),
                    configured: true,
                },
                None => ResidentLibrary::At {
                    dir: self.platform_dir.clone(),
                    configured: false,
                },
            }),
        }
    }

    /// 是否还没配置过（决定这次写入是「首启」还是「改库」）。
    fn unconfigured(&self) -> Result<bool, String> {
        let cfg = self.platform_dir.join(CONFIG_FILE_NAME);
        match &self.store {
            Some(store) => Ok(store.read().map_err(|e| e.to_string())?.is_none() || !cfg.exists()),
            None => Ok(!cfg.exists()),
        }
    }

    /// 唯一写者。首启（未配置）= 建库目录、写首启模板；改库 = 校验（存在、可写、不嵌套）后
    /// 只改 `data_dir`。然后写正本。返回 config.toml 路径。重启后台服务后生效。
    pub fn set(&self, library: &str) -> Result<PathBuf, String> {
        let library = config::normalize_separators(library.trim());
        let cfg = if self.unconfigured()? {
            config::init_config(&self.platform_dir, &library)?
        } else {
            config::set_library(&self.platform_dir, &library)?
        };
        if let Some(store) = &self.store {
            store
                .write(library.as_bytes())
                .map_err(|e| config::ui_err("ui.err_set_library", &[("err", &e)]))?;
        }
        Ok(cfg)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Default, Clone)]
    struct Mem(Arc<Mutex<Option<Vec<u8>>>>);
    impl platform::SecretBlobStore for Mem {
        fn read(&self) -> platform::Result<Option<Vec<u8>>> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn write(&self, b: &[u8]) -> platform::Result<()> {
            *self.0.lock().unwrap() = Some(b.to_vec());
            Ok(())
        }
        fn delete(&self) -> platform::Result<()> {
            *self.0.lock().unwrap() = None;
            Ok(())
        }
        fn location(&self) -> String {
            "mem".into()
        }
    }

    fn resident(loc: &LibraryLocation) -> ResidentLibrary {
        let cfg = Config::load(Some(&loc.platform_dir.join(CONFIG_FILE_NAME))).unwrap();
        loc.resident_library(&cfg).unwrap()
    }

    /// 有正本时：没配置过 ⇒ 未配置；写过 ⇒ 用正本；**改 config.toml 不生效**。
    /// 反证：resident_library 改成读 config.data_dir ⇒ 最后一条红。
    #[test]
    fn with_a_secure_store_only_the_store_counts() {
        let tmp = tempfile::tempdir().unwrap();
        let mem = Mem::default();
        let loc = LibraryLocation::with(Some(Box::new(mem.clone())), tmp.path().join("platform"));
        assert_eq!(resident(&loc), ResidentLibrary::Unconfigured);

        let lib = tmp.path().join("Library A");
        loc.set(lib.to_str().unwrap()).unwrap();
        assert!(lib.is_dir(), "首启建库目录");
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib.clone(),
                configured: true
            }
        );

        // 同用户程序把 config.toml 改到别处：daemon 不认。
        std::fs::write(
            loc.platform_dir.join(CONFIG_FILE_NAME),
            "data_dir = \"/tmp/attacker-library\"\n",
        )
        .unwrap();
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib,
                configured: true
            }
        );
    }

    /// 改库走校验：目标不存在 ⇒ 报错、正本不动。
    #[test]
    fn changing_the_library_is_validated_and_keeps_the_store_on_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let mem = Mem::default();
        let loc = LibraryLocation::with(Some(Box::new(mem.clone())), tmp.path().join("platform"));
        let a = tmp.path().join("a");
        loc.set(a.to_str().unwrap()).unwrap();
        let err = loc
            .set(tmp.path().join("missing").to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("ui.err_library_target_missing"), "{err}");
        assert_eq!(
            mem.0.lock().unwrap().as_deref(),
            Some(a.to_str().unwrap().as_bytes())
        );
        let b = tmp.path().join("b");
        std::fs::create_dir_all(&b).unwrap();
        loc.set(b.to_str().unwrap()).unwrap();
        assert_eq!(
            mem.0.lock().unwrap().as_deref(),
            Some(b.to_str().unwrap().as_bytes())
        );
    }

    /// 没有安全存储的平台：沿用 config 语义（没配置 ⇒ 平台目录、非显式）。
    #[test]
    fn without_a_secure_store_config_toml_is_the_authority() {
        let tmp = tempfile::tempdir().unwrap();
        let loc = LibraryLocation::with(None, tmp.path().join("platform"));
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: tmp.path().join("platform"),
                configured: false
            }
        );
        let lib = tmp.path().join("lib");
        loc.set(lib.to_str().unwrap()).unwrap();
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib,
                configured: true
            }
        );
    }
}
