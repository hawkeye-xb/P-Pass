//! P-Pass storage daemon — production wiring (grows card by card).
//!
//! T-030: bind the endpoint, open the index, run the ctrl router with the
//! authz checkpoint. Pairing/IPC/tray integration land with T-031/T-034.

use daemon::{Config, Router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let config = Config::load(None)?;
    let data_dir = config
        .data_dir
        .clone()
        .ok_or_else(|| anyhow::anyhow!("data_dir 未配置：请在 config.toml 设置 data_dir"))?;
    std::fs::create_dir_all(&data_dir)?;

    let db = storage::Db::open(&data_dir.join(".ppf/index.sqlite")).await?;
    let transport = transport::IrohTransport::bind(transport::TransportConfig::from_endpoints(
        config.relay_urls.clone(),
        vec![transport::ALPN_CTRL.into()],
    ))
    .await?;

    println!("P-Pass daemon 已启动");
    println!("NodeId: {}", transport.node_id());
    println!("库目录: {}", data_dir.display());

    // Pairing (T-031): issue one QR token at startup; confirmations come
    // from the console until the tray UI lands (T-041/T-034 wire IPC).
    let (pairing, mut pending) = daemon::Pairing::new(db.clone(), transport.node_id());
    let qr = pairing.start(rand_token()?, unix_ms_now());
    println!("配对二维码内容（10 分钟内有效）: {qr}");
    // §2.2 要求 owner 亲手确认——托盘 UI (T-041) 之前用控制台代替，
    // 绝不默认放行。
    tokio::spawn(async move {
        while let Some(req) = pending.recv().await {
            println!(
                "配对请求：设备「{}」请求以 {:?} 身份加入。允许？[y/N] ",
                req.device_name, req.role
            );
            let answer = tokio::task::spawn_blocking(|| {
                let mut line = String::new();
                std::io::stdin().read_line(&mut line).ok();
                line.trim().eq_ignore_ascii_case("y")
            })
            .await
            .unwrap_or(false);
            println!(
                "{}",
                if answer {
                    "已允许。"
                } else {
                    "已拒绝。"
                }
            );
            req.decide(answer);
        }
    });

    Router::new(db, "P-Pass 存储端")
        .with_pairing(pairing)
        .serve(&transport)
        .await;
    Ok(())
}

/// 32 random bytes from the OS (via std's RandomState hashing entropy is
/// NOT enough — use getrandom through the `rand`-free std path).
fn rand_token() -> anyhow::Result<[u8; 32]> {
    let mut token = [0u8; 32];
    getrandom::fill(&mut token).map_err(|e| anyhow::anyhow!("系统随机数不可用：{e}"))?;
    Ok(token)
}

fn unix_ms_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}
