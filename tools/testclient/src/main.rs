//! testclient — integration-test harness for the P-Pass daemon (T-005).
//!
//! Skeleton card: argument parsing + human-readable "daemon unreachable"
//! errors. Real flows land with the P3 cards:
//! pair (T-031) · backup (T-032) · browse (T-033) · revoke-check (T-030).

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "testclient", about = "P-Pass daemon 集成测试客户端", version)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// 配对流程测试：扫码令牌 → PairRequest → 等待确认（T-031 实装）
    Pair {
        /// ppf://pair?... 配对串
        #[arg(long)]
        token: Option<String>,
    },
    /// 备份剧本：推送 N 个文件走 manifest→missing→push→commit（T-032 实装）
    Backup {
        /// 模拟推送的文件数
        #[arg(long, default_value = "500")]
        files: u32,
    },
    /// 浏览剧本：分页遍历时间线 + 拉取缩略图校验（T-033 实装）
    Browse {
        /// 每页条数
        #[arg(long, default_value = "200")]
        limit: u32,
    },
    /// 吊销验证：以未配对/已吊销身份连接，期望 not_authorized（T-030 实装）
    RevokeCheck,
}

fn main() {
    let cli = Cli::parse();
    let cmd_name = match &cli.cmd {
        Cmd::Pair { .. } => "pair",
        Cmd::Backup { .. } => "backup",
        Cmd::Browse { .. } => "browse",
        Cmd::RevokeCheck => "revoke-check",
    };

    // Skeleton behaviour: every subcommand first needs a daemon connection,
    // and none exists yet — fail with a human-readable message (契约).
    match connect_daemon() {
        Ok(()) => {
            eprintln!("`{cmd_name}` 的真实逻辑随 P3 任务卡实装，当前为骨架。");
            std::process::exit(2);
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

/// Placeholder daemon connection. The real IPC (local socket + token)
/// arrives with T-034; until then this always fails — with a message a
/// human can act on, not a stack trace.
fn connect_daemon() -> anyhow::Result<()> {
    anyhow::bail!(
        "无法连接到 P-Pass daemon：它可能还没有运行。\n\
         请先启动 daemon（`just dev-daemon`）后重试；\n\
         若已启动仍失败，检查数据目录下的 IPC 令牌是否可读。"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory;

    #[test]
    fn help_lists_all_four_subcommands() {
        let cmd = Cli::command();
        let names: Vec<_> = cmd.get_subcommands().map(|c| c.get_name()).collect();
        for expected in ["pair", "backup", "browse", "revoke-check"] {
            assert!(names.contains(&expected), "missing subcommand {expected}");
        }
        assert_eq!(names.len(), 4);
    }

    #[test]
    fn cli_definition_is_consistent() {
        Cli::command().debug_assert();
    }
}
