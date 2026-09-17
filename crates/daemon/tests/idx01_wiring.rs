//! IDX-01：收编方向必须**真的接在** daemon 启动路径上。
//!
//! 为什么单独写这条：DEVLOG-01 的教训——那次新加的两个函数写好了、测好了，
//! 但 `main.rs` 没调，生产上是死代码，谁都没发现。`adopt_orphans` 是同一个
//! 形状：单测全绿、`Reconcile` 里也接了，但只要 `main.rs` 漏掉
//! `with_local_node_id`，收编开关就是关的，照片照样看不见，而所有单测依然绿。
//! 这条断言堵的就是那个缺口。

use std::fs;
use std::path::PathBuf;

fn main_rs() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/main.rs");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("读不到 {}: {e}", path.display()))
}

#[test]
fn the_daemon_turns_on_orphan_adoption_at_startup() {
    let code = main_rs();
    let reconcile_at = code
        .find("Reconcile::new(")
        .expect("main.rs 不再构造 Reconcile 了——本测试的前提已失效，请重新表述");
    let tail = &code[reconcile_at..];
    // 建造者链在下一个语句结束前——够长的窗口，又不会误吃到别处。
    let chain_end = tail.find(';').expect("Reconcile 构造语句没有分号？");
    let chain = &tail[..chain_end];

    assert!(
        chain.contains("with_local_node_id"),
        "IDX-01: main.rs 的常驻对账器必须接 `with_local_node_id`，\
         否则只剩 SYNC-01 的删幽灵那一半——索引一丢，照片就永远回不来，\
         而单测会全绿（DEVLOG-01 同款死代码陷阱）。实际的建造者链：{chain}"
    );
}
