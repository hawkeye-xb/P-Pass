//! WATCH-01 acceptance: real notify watcher over a temp library — writes
//! get ingested within seconds, deletes get reconciled, junk is ignored.
//!
//! Poll-with-timeout assertions: filesystem events are async by nature
//! (FSEvents latency, debounce window), so tests never assert on wall
//! time — they poll until the index converges or the deadline expires.

use std::path::PathBuf;
use std::time::Duration;

use daemon::events::{self, TIMELINE_INVALIDATED};
use daemon::LibraryWatcher;
use storage::Db;

const NODE_ID: [u8; 32] = [7u8; 32];

struct Fixture {
    dir: tempfile::TempDir,
    db: Db,
    events: tokio::sync::broadcast::Receiver<serde_json::Value>,
    _watcher: LibraryWatcher,
}

async fn setup(debounce: Duration) -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    // #1253：真库都带库标记；没有它的目录在删除方向上当「库不在」。
    std::fs::create_dir_all(dir.path().join(".ppf")).unwrap();
    let db = Db::open(&dir.path().join("index.sqlite")).await.unwrap();
    let (bus, rx) = events::bus();
    let watcher = LibraryWatcher::new(db.clone(), dir.path(), NODE_ID, bus).with_debounce(debounce);
    watcher.spawn().unwrap();
    Fixture {
        dir,
        db,
        events: rx,
        _watcher: watcher,
    }
}

/// 往 originals 写一个媒体文件（假字节即可——ingest 对不可解码图片
/// 走 `image_dimensions` 失败分支，dimensions 为 None 不报错）。
async fn write_media(f: &Fixture, rel: &str, bytes: &[u8]) -> PathBuf {
    let path = f.dir.path().join("originals").join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, bytes).unwrap();
    path
}

async fn asset_count(f: &Fixture) -> i64 {
    f.db.count_assets().await.unwrap()
}

/// 轮询直到 `probe` 为真或超时（60s 仅作防挂死上限，不靠短超时赌快慢）。
async fn wait_until<F, Fut>(probe: F, what: &str)
where
    F: Fn() -> Fut,
    Fut: futures_core::Future<Output = bool>,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(60);
    while tokio::time::Instant::now() < deadline {
        if probe().await {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("timeout waiting for {what}");
}

/// 等下一条 `timeline.invalidated` 事件——既是事件契约验证，也是初始批次节流窗口
/// （`DEFAULT_THROTTLE_WINDOW`）已完整 flush 的确定性信号，替代固定 `sleep(1600ms)`。
async fn await_invalidated(
    events: &mut tokio::sync::broadcast::Receiver<serde_json::Value>,
    what: &str,
) {
    let got = tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            match events.recv().await {
                Ok(v) if v.get("event").and_then(|e| e.as_str()) == Some(TIMELINE_INVALIDATED) => {
                    break true;
                }
                Ok(_) | Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break false,
            }
        }
    })
    .await
    .unwrap_or(false);
    assert!(got, "{what}: 60s 内未收到 timeline.invalidated");
}

async fn count_eq(f: &Fixture, n: i64) -> bool {
    match f.db.count_assets().await {
        Ok(c) => c == n,
        Err(_) => false,
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn new_media_file_is_ingested_within_seconds() {
    let f = setup(Duration::from_millis(100)).await;
    write_media(&f, "IMG_0001.jpg", b"fake-jpeg-bytes").await;

    wait_until(|| count_eq(&f, 1), "ingest of new file").await;

    // 宽容落位（2026-08-21 裁决）：originals/ 是**用户的**目录，已经在树内
    // 的文件就地采纳，绝不搬走。canonical 布局只用于我们自己从手机收到的
    // 文件（那些此刻还在 staging，没有家）。
    assert!(
        f.dir.path().join("originals/IMG_0001.jpg").exists(),
        "库内文件必须留在用户放的位置"
    );
    let hex: String = NODE_ID.iter().map(|b| format!("{b:02x}")).collect();
    assert!(
        !f.dir.path().join("originals").join(&hex).exists(),
        "不该为库内文件建 canonical 目录"
    );
    // 归属：watcher 发现的库内文件记本机 node_id（与 rebuild 的口径一致）。
    let rows = f.db.list_asset_paths().await.unwrap();
    assert_eq!(rows[0].1, "originals/IMG_0001.jpg");
}

#[tokio::test(flavor = "multi_thread")]
async fn delete_is_reconciled_and_invalidated_emitted() {
    let mut f = setup(Duration::from_millis(100)).await;
    let path = write_media(&f, "2026/08/IMG_0002.jpg", b"fake-jpeg-bytes-2").await;
    wait_until(|| count_eq(&f, 1), "initial ingest").await;

    // #1087：等初始入库批次的 `timeline.invalidated` 真正 flush 后再删除，
    // 替代原先固定 `sleep(1600ms)`（既证明创建批次已过防抖与节流窗口，也保证删除能触发新事件）。
    await_invalidated(&mut f.events, "initial ingest flush before delete").await;
    std::fs::remove_file(&path).unwrap();

    // 索引收敛到 0 + 收到删除对应的 invalidated 事件。
    wait_until(|| count_eq(&f, 0), "reconcile of delete").await;
    await_invalidated(&mut f.events, "删除后必须 emit timeline.invalidated").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn junk_and_hidden_files_are_not_ingested() {
    let f = setup(Duration::from_millis(100)).await;
    write_media(&f, ".DS_Store", b"junk").await;
    write_media(&f, "Thumbs.db", b"junk").await;
    write_media(&f, "notes.txt", b"hello").await;
    // #1087：反向断言不靠固定 sleep(800ms) 猜窗口——写一张同目录参照媒体文件，
    // 等它被 watcher 真实入库后，验证索引里只有参照文件，非媒体/隐藏文件全部被忽略。
    write_media(&f, "SENTINEL_JUNK_CHECK.jpg", b"sentinel-jpeg-bytes").await;

    wait_until(|| count_eq(&f, 1), "sentinel media after junk files").await;
    let rows = f.db.list_asset_paths().await.unwrap();
    assert_eq!(rows.len(), 1, "非媒体/隐藏文件不得 ingest: {rows:?}");
    assert_eq!(rows[0].1, "originals/SENTINEL_JUNK_CHECK.jpg");
}

#[tokio::test(flavor = "multi_thread")]
async fn ingest_self_events_are_idempotent() {
    // 场景：ingest 把文件移入 canonical 布局后，watcher 看到 create 事件
    // 再扫一次——必须因 hash dedup 返回 Duplicate，不重复入库、不报错。
    let f = setup(Duration::from_millis(100)).await;
    write_media(&f, "IMG_0003.jpg", b"same-bytes").await;
    wait_until(|| count_eq(&f, 1), "first ingest").await;

    // #1087：用第二张参照文件推动下一轮防抖扫描，代替固定 sleep(600ms)。
    write_media(&f, "IMG_0003_SENTINEL.jpg", b"distinct-sentinel-bytes").await;
    wait_until(|| count_eq(&f, 2), "sentinel batch after self-events").await;
    let rows = f.db.list_asset_paths().await.unwrap();
    assert_eq!(
        rows.len(),
        2,
        "自产事件扫描必须幂等（Duplicate 跳过）: {rows:?}"
    );
    assert_eq!(
        rows.iter()
            .filter(|(_, p)| p == "originals/IMG_0003.jpg")
            .count(),
        1,
        "IMG_0003.jpg 只能入库一次"
    );
}

// ---------------------------------------------------------------------------
// WATCH-02 探针：三种删除形状 + Finder 内部移动。
// ---------------------------------------------------------------------------

/// #1087：等初始入库批次的 `timeline.invalidated` 节流事件真正 flush，替代固定 `sleep(1600ms)`。
async fn settle(f: &mut Fixture) {
    await_invalidated(&mut f.events, "settle initial ingest batch").await;
}

/// 用户自己建的日期目录——库内布局归用户，测试不该假设我们的 canonical 形状。
const USER_TREE: &str = "2026/08";

#[tokio::test(flavor = "multi_thread")]
async fn removing_a_whole_subtree_is_reconciled() {
    // 形状二：整棵子树被 remove_dir_all（rm -rf 语义）。
    let mut f = setup(Duration::from_millis(100)).await;
    write_media(&f, &format!("{USER_TREE}/IMG_A.jpg"), b"bytes-a").await;
    write_media(&f, &format!("{USER_TREE}/IMG_B.jpg"), b"bytes-b").await;
    wait_until(|| count_eq(&f, 2), "initial ingest").await;
    settle(&mut f).await;

    std::fs::remove_dir_all(f.dir.path().join("originals/2026")).unwrap();
    wait_until(|| count_eq(&f, 0), "reconcile of whole-subtree removal").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn trashing_a_subtree_is_reconciled() {
    // 形状三：Finder「删除」= 把目录 rename 进 ~/.Trash（同卷改名）。
    let mut f = setup(Duration::from_millis(100)).await;
    write_media(&f, &format!("{USER_TREE}/IMG_C.jpg"), b"bytes-c").await;
    write_media(&f, &format!("{USER_TREE}/IMG_D.jpg"), b"bytes-d").await;
    wait_until(|| count_eq(&f, 2), "initial ingest").await;
    settle(&mut f).await;

    let trash = f.dir.path().join("trash-outside-originals");
    std::fs::rename(f.dir.path().join("originals/2026"), &trash).unwrap();
    wait_until(|| count_eq(&f, 0), "reconcile of trash-style rename").await;
}

#[tokio::test(flavor = "multi_thread")]
async fn moving_a_file_inside_originals_keeps_it_indexed() {
    // 用户在 Finder 里把照片拖进自建目录（分类）——文件还在库里，
    // 索引必须重新指向新位置，绝不能把行删掉让照片凭空消失。
    let mut f = setup(Duration::from_millis(100)).await;
    let start = write_media(&f, &format!("{USER_TREE}/IMG_E.jpg"), b"bytes-e").await;
    wait_until(|| count_eq(&f, 1), "initial ingest").await;
    settle(&mut f).await;

    let album = f.dir.path().join("originals").join("我的婚礼");
    std::fs::create_dir_all(&album).unwrap();
    let dest = album.join("IMG_E.jpg");
    std::fs::rename(&start, &dest).unwrap();

    // #823：等索引**收敛**到新位置，而不是固定睡 1.6s 再赌它已经收敛——
    // runner 争用时 watcher 事件、防抖、入库会多走一会儿，固定睡眠就先到了。
    // 上限仍是 wait_until 的 10s；收敛之后再逐条断言最终状态。
    wait_until(
        || async {
            f.db.list_asset_paths()
                .await
                .map(|p| p.len() == 1 && p[0].1 == "originals/我的婚礼/IMG_E.jpg")
                .unwrap_or(false)
        },
        "index follows the in-library move",
    )
    .await;
    assert!(dest.exists(), "用户放的位置不该被我们动");
    assert_eq!(
        asset_count(&f).await,
        1,
        "库内移动是重新分类，不是删除——索引必须保留"
    );
    // 只数行数会漏掉「指向哪里」：行还在但 rel_path 停在旧住址，
    // 缩略图/原图取不到，等于照片坏了。
    let paths = f.db.list_asset_paths().await.unwrap();
    assert_eq!(
        paths[0].1, "originals/我的婚礼/IMG_E.jpg",
        "rel_path 必须改指用户摆的新位置"
    );
    assert!(
        f.dir.path().join(&paths[0].1).exists(),
        "索引指向的路径必须真实存在"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn whole_subtree_removal_emits_invalidated() {
    // 索引减到位之外，前端要收到 timeline.invalidated 才会重画照片墙。
    let mut f = setup(Duration::from_millis(100)).await;
    write_media(&f, &format!("{USER_TREE}/IMG_F.jpg"), b"bytes-f").await;
    wait_until(|| count_eq(&f, 1), "initial ingest").await;
    settle(&mut f).await;

    std::fs::remove_dir_all(f.dir.path().join("originals/2026")).unwrap();
    wait_until(|| count_eq(&f, 0), "reconcile of whole-subtree removal").await;
    await_invalidated(
        &mut f.events,
        "整棵子树删除后必须 emit timeline.invalidated",
    )
    .await;
}
