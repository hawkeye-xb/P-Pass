//! #1115：测试沙盒——`--ephemeral` 启动时整体选定的一套配置。
//!
//! 签名的 daemon 二进制谁都能带参数运行，所以「测试用的口子」必须是一个**整体**，不能
//! 是几个能分开拧的开关。沙盒 = 以下几条同时成立，写死在代码里、由测试守着：
//! - 存储根是本进程自建的一次性临时目录（仅本用户可访问），启动时在 stdout 打一行
//!   [`STDOUT_PREFIX`] 告诉脚本它在哪；
//! - 身份是内存里的随机身份，配对记录只在这个临时库里——不读写钥匙串（`identity::for_run`、
//!   `main.rs` 的 `pairing_store`）；
//! - IPC 用令牌认证，令牌文件在沙盒目录里，socket 名由随机身份派生；
//! - 不连接常驻 daemon（不做单实例交接）；
//! - **不接受任何路径输入**：[`FORBIDDEN_ENV`] 里任何一个出现就拒绝启动；不读平台
//!   config.toml；CLI 没有路径参数。
//!
//! 持有沙盒令牌的人能做的事 = 自己从源码编一个 daemon 能做的事：它不持有真库、真身份、
//! 真白名单。

use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// 沙盒拒收的路径类环境变量（给出任何一个即拒绝启动）。
pub const FORBIDDEN_ENV: &[&str] = &["PPF_DATA_DIR", "PPF_LOG_FILE"];

/// stdout 上告诉脚本沙盒目录的那一行的前缀（机读契约，`tools/ipc-lib.sh` 读它）。
pub const STDOUT_PREFIX: &str = "SANDBOX: ";

/// 一次运行的沙盒。
#[derive(Debug, Clone)]
pub struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    /// 在系统临时目录下新建本次运行专用的目录（0700）。
    pub fn create() -> Result<Self, String> {
        use platform::PlatformAdapter as _;
        let mut rand = [0u8; 8];
        getrandom::fill(&mut rand).map_err(|e| format!("取随机数失败：{e}"))?;
        let suffix: String = rand.iter().map(|b| format!("{b:02x}")).collect();
        let root =
            std::env::temp_dir().join(format!("ppass-sandbox-{}-{suffix}", std::process::id()));
        platform::adapter()
            .prepare_private_dir(&root)
            .map_err(|e| format!("建沙盒目录 {} 失败：{e}", root.display()))?;
        Ok(Self { root })
    }

    /// 沙盒目录 = 这次运行的照片库根（令牌文件、索引、原图都在里面）。
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// stdout 上的机读行。
    pub fn stdout_line(&self) -> String {
        format!("{STDOUT_PREFIX}{}", self.root.display())
    }
}

/// 环境里出现了哪些沙盒不接受的路径输入（空值不算）。
pub fn forbidden_inputs(env: &HashMap<String, String>) -> Vec<&'static str> {
    FORBIDDEN_ENV
        .iter()
        .copied()
        .filter(|k| env.get(*k).is_some_and(|v| !v.is_empty()))
        .collect()
}

/// 拒绝启动时的说明（stderr 一行）。
pub fn rejection(given: &[&str]) -> String {
    format!(
        "--ephemeral 是测试沙盒：存储位置由进程自己建，不接受任何路径输入。去掉 {} 再启动。",
        given.join(" / ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 反证：从 FORBIDDEN_ENV 里删掉 PPF_DATA_DIR，或 forbidden_inputs 忽略它 ⇒ 第一条红。
    #[test]
    fn any_path_input_is_rejected() {
        let env = |pairs: &[(&str, &str)]| -> HashMap<String, String> {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        assert_eq!(
            forbidden_inputs(&env(&[("PPF_DATA_DIR", "/x")])),
            ["PPF_DATA_DIR"]
        );
        assert_eq!(
            forbidden_inputs(&env(&[("PPF_LOG_FILE", "/l"), ("PPF_DATA_DIR", "/x")])),
            ["PPF_DATA_DIR", "PPF_LOG_FILE"]
        );
        assert!(
            forbidden_inputs(&env(&[("PPF_DATA_DIR", "")])).is_empty(),
            "空值不算"
        );
        assert!(forbidden_inputs(&env(&[("PPF_BIND_ADDR", "127.0.0.1:0")])).is_empty());
    }

    #[test]
    fn sandbox_dir_is_fresh_private_and_announced() {
        let a = Sandbox::create().unwrap();
        let b = Sandbox::create().unwrap();
        assert_ne!(a.root(), b.root(), "每次运行一个新目录");
        assert!(a.root().is_dir());
        assert_eq!(a.stdout_line(), format!("SANDBOX: {}", a.root().display()));
        let _ = std::fs::remove_dir_all(a.root());
        let _ = std::fs::remove_dir_all(b.root());
    }
}
