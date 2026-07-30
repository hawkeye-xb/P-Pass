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

    Router::new(db, "P-Pass 存储端").serve(&transport).await;
    Ok(())
}
