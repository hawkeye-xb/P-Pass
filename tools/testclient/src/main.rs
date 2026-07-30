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
        /// ppf://pair?node=<hex>&t=<token> 配对串（daemon 启动时打印）
        #[arg(long)]
        token: Option<String>,
        /// 报给存储端看的设备名
        #[arg(long, default_value = "testclient")]
        name: String,
    },
    /// 备份剧本：推送 N 个文件走 manifest→missing→接收→commit（T-032 实装）
    Backup {
        /// 模拟推送的文件数
        #[arg(long, default_value = "500")]
        files: u32,
        /// 存储端 NodeId（64 位 hex，daemon 启动时打印）
        #[arg(long)]
        node: String,
    },
    /// 浏览剧本：分页遍历时间线 + 拉取缩略图校验（T-033 实装）
    Browse {
        /// 每页条数
        #[arg(long, default_value = "200")]
        limit: u32,
    },
    /// 吊销验证：以未配对/已吊销身份连接，期望 not_authorized（T-030 实装）
    RevokeCheck {
        /// 存储端 NodeId（64 位 hex，daemon 启动时打印）
        #[arg(long)]
        node: String,
    },
}

fn main() {
    let cli = Cli::parse();
    let cmd_name = match &cli.cmd {
        Cmd::Pair {
            token: Some(qr),
            name,
        } => {
            std::process::exit(run_async(pair(qr, name)));
        }
        Cmd::Pair { token: None, .. } => {
            eprintln!("缺少 --token：把 daemon 启动时打印的 ppf://pair?... 串传进来。");
            std::process::exit(1);
        }
        Cmd::Backup { files, node } => {
            let (files, node) = (*files, node.clone());
            std::process::exit(run_async(backup(files, &node)));
        }
        Cmd::Browse { .. } => "browse",
        Cmd::RevokeCheck { node } => {
            std::process::exit(run_async(revoke_check(node)));
        }
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

/// Run one async scenario to completion; success message on stdout.
fn run_async(fut: impl std::future::Future<Output = anyhow::Result<String>>) -> i32 {
    let rt = match tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("无法启动异步运行时：{e}");
            return 1;
        }
    };
    match rt.block_on(fut) {
        Ok(msg) => {
            println!("{msg}");
            0
        }
        Err(e) => {
            eprintln!("失败：{e:#}");
            1
        }
    }
}

/// T-031 剧本：解析 QR 串 → 连接存储端 → PairRequest → 等 owner 确认。
async fn pair(qr: &str, name: &str) -> anyhow::Result<String> {
    let rest = qr
        .strip_prefix("ppf://pair?node=")
        .ok_or_else(|| anyhow::anyhow!("配对串必须以 ppf://pair?node= 开头：{qr}"))?;
    let (node_hex, token) = rest
        .split_once("&t=")
        .ok_or_else(|| anyhow::anyhow!("配对串缺少 &t=<token> 段：{qr}"))?;
    let daemon: transport::NodeId = node_hex
        .parse()
        .map_err(|_| anyhow::anyhow!("配对串里的 NodeId 不合法：{node_hex}"))?;

    let tp = bind_endpoint().await?;
    let mut stream = connect_ctrl(&tp, daemon).await?;
    let req = proto::Req {
        id: "pair".into(),
        method: "pair.request".into(),
        params: serde_json::to_value(proto::PairRequest {
            token: token.trim().into(),
            device_name: name.into(),
            role: "member".into(),
        })?,
        ..Default::default()
    };
    println!("已发送配对请求，等待存储端上的确认……");
    let resp = roundtrip(&mut stream, &req).await?;
    match resp.error {
        None => {
            let accepted: proto::PairAccepted =
                serde_json::from_value(resp.result.unwrap_or_default())?;
            Ok(format!(
                "✅ 配对成功：已加入「{}」。本机 NodeId: {}",
                accepted.storage_device_name,
                tp.node_id()
            ))
        }
        Some(err) => anyhow::bail!(
            "配对被拒绝（{} / {}）——令牌过期、已用过，或 owner 拒绝了。",
            err.code,
            err.msg_key
        ),
    }
}

/// T-032 剧本：生成 N 个混合文件（每 10 个 1 个重复内容），本机作为
/// blobs 提供方，走 begin → manifest → missing → commit 全链。
async fn backup(files: u32, node: &str) -> anyhow::Result<String> {
    let daemon: transport::NodeId = node
        .parse()
        .map_err(|_| anyhow::anyhow!("--node 不是合法的 64 位 hex NodeId：{node}"))?;
    let dir = tempfile::tempdir()?;

    let tp = bind_endpoint().await?;
    let mut blobs = transport::Blobs::open(&tp, &dir.path().join("blobs")).await?;
    blobs.serve();

    // 生成语料：确定性伪随机内容，每 10 个复用前一个的内容（去重演示）。
    let mut items = Vec::new();
    let mut s: u64 = 0x5EED_2026_0730_0005;
    let mut prev: Vec<u8> = Vec::new();
    for i in 0..files {
        let content = if i > 0 && i % 10 == 0 {
            prev.clone()
        } else {
            let mut v = i.to_le_bytes().to_vec();
            for _ in 0..256 {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                v.extend_from_slice(&s.to_le_bytes());
            }
            v
        };
        let hash = *blake3::hash(&content).as_bytes();
        let hash_hex: String = hash.iter().map(|b| format!("{b:02x}")).collect();
        let name = format!("IMG_{i:04}.jpg");
        let path = dir.path().join(&name);
        std::fs::write(&path, &content)?;
        blobs.import(hash, &path).await?;
        items.push(proto::BackupItem {
            hash: hash_hex,
            file_name: name,
            media_type: "image/jpeg".into(),
        });
        prev = content;
    }

    let call = |method: &str, params: serde_json::Value| {
        let tp = tp.clone();
        let method = method.to_string();
        async move {
            let mut stream = connect_ctrl(&tp, daemon).await?;
            let req = proto::Req {
                id: method.clone(),
                method,
                params,
                ..Default::default()
            };
            roundtrip(&mut stream, &req).await
        }
    };

    let resp = call("backup.begin", serde_json::Value::Null).await?;
    anyhow::ensure!(resp.ok, "backup.begin 被拒：{:?}", resp.error);
    let manifest = proto::BackupManifest {
        hashes: vec![],
        items,
    };
    let resp = call("backup.manifest", serde_json::to_value(&manifest)?).await?;
    anyhow::ensure!(resp.ok, "backup.manifest 失败：{:?}", resp.error);
    let missing: proto::BackupMissing = serde_json::from_value(resp.result.unwrap_or_default())?;
    println!(
        "清单 {} 个文件，存储端缺 {} 个，开始传输……",
        files,
        missing.hashes.len()
    );
    let resp = call(
        "backup.commit",
        serde_json::to_value(&proto::BackupCommit {
            generation: Some(files as i64),
        })?,
    )
    .await?;
    match resp.error {
        None => Ok(format!(
            "✅ 备份完成：{} 个文件（含重复内容），存储端实收 {} 个新 blob，水位已推进。",
            files,
            missing.hashes.len()
        )),
        Some(err) => anyhow::bail!(
            "commit 失败（{} / {}），重跑即可续传。",
            err.code,
            err.msg_key
        ),
    }
}

async fn bind_endpoint() -> anyhow::Result<transport::IrohTransport> {
    transport::IrohTransport::bind(transport::TransportConfig::from_endpoints(
        Vec::new(),
        vec![transport::ALPN_CTRL.into()],
    ))
    .await
    .map_err(|e| anyhow::anyhow!("绑定本机端点失败：{e}"))
}

async fn connect_ctrl(
    tp: &transport::IrohTransport,
    daemon: transport::NodeId,
) -> anyhow::Result<transport::BiStream> {
    use transport::Transport as _;
    tp.connect(daemon, transport::ALPN_CTRL)
        .await
        .map_err(|e| anyhow::anyhow!("连接存储端失败（它在线吗？）：{e}"))
}

/// Send one request, half-close, read the one response.
async fn roundtrip(
    stream: &mut transport::BiStream,
    req: &proto::Req,
) -> anyhow::Result<proto::Resp> {
    let frame = proto::codec::encode(req)?;
    stream
        .send_frame(&frame)
        .await
        .map_err(|e| anyhow::anyhow!("发送请求失败：{e}"))?;
    stream.finish().ok();
    let frame = stream
        .recv_frame()
        .await
        .map_err(|e| anyhow::anyhow!("等待响应失败：{e}"))?
        .ok_or_else(|| anyhow::anyhow!("存储端没有回应就关闭了流"))?;
    Ok(proto::codec::decode(&frame)?)
}

async fn revoke_check(node: &str) -> anyhow::Result<String> {
    let daemon: transport::NodeId = node
        .parse()
        .map_err(|_| anyhow::anyhow!("--node 不是合法的 64 位 hex NodeId：{node}"))?;

    let tp = bind_endpoint().await?;
    let mut stream = connect_ctrl(&tp, daemon).await?;
    let req = proto::Req {
        id: "revoke-check".into(),
        method: "timeline.page".into(),
        params: serde_json::Value::Null,
        ..Default::default()
    };
    let resp = roundtrip(&mut stream, &req).await?;

    match resp.error {
        Some(err) if err.code == proto::codes::NOT_AUTHORIZED => Ok(format!(
            "✅ 授权检查点在岗：本机被正确拒绝（{}）。吊销/未配对语义生效。",
            err.msg_key
        )),
        Some(err) => anyhow::bail!(
            "收到了错误但不是 NOT_AUTHORIZED：{} / {}",
            err.code,
            err.msg_key
        ),
        None => anyhow::bail!("存储端竟然放行了未授权设备的浏览请求——检查点失守！"),
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
