//! 诊断工具（默认 ignore，手动跑）：把一个目录的各种操作真实投递的事件
//! 原样打印，用来回答「操作系统到底告诉我们什么」。
//!
//!     cargo test -p daemon --test fsevents_shapes -- --ignored --nocapture
//!
//! 2026-08-21 macOS 实测结论见 docs/product/2026-08-21-macos-fs-events.md。
//! 一条被断言锁住的不变量单独留在下面（根目录被删重建后监听还活着）。
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::sync::mpsc;
use std::time::Duration;

fn drain(rx: &mpsc::Receiver<Event>, root: &std::path::Path, label: &str) {
    std::thread::sleep(Duration::from_millis(900));
    println!("\n### {label}");
    let mut n = 0;
    while let Ok(ev) = rx.try_recv() {
        n += 1;
        let paths: Vec<String> = ev
            .paths
            .iter()
            .map(|p| p.strip_prefix(root).unwrap_or(p).display().to_string())
            .collect();
        println!("  {:?}  paths={:?}", ev.kind, paths);
    }
    if n == 0 {
        println!("  （零事件）");
    }
}

#[test]
#[ignore = "诊断工具，手动跑；输出给人看，不做断言"]
fn dump_raw_fsevents_for_every_shape() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let watched = root.join("watched");
    std::fs::create_dir_all(&watched).unwrap();
    let outside = root.join("outside");
    std::fs::create_dir_all(&outside).unwrap();

    let (tx, rx) = mpsc::channel::<Event>();
    let mut w: RecommendedWatcher = notify::recommended_watcher(move |r: notify::Result<Event>| {
        if let Ok(e) = r {
            let _ = tx.send(e);
        }
    })
    .unwrap();
    w.watch(&watched, RecursiveMode::Recursive).unwrap();
    std::thread::sleep(Duration::from_millis(400));
    println!("watcher 实现 = {:?}", RecommendedWatcher::kind());

    std::fs::write(watched.join("a.jpg"), b"aaa").unwrap();
    drain(&rx, &root, "① 新建文件 a.jpg");

    std::fs::write(watched.join("a.jpg"), b"aaaaaa").unwrap();
    drain(&rx, &root, "② 改写同一文件内容");

    std::fs::rename(watched.join("a.jpg"), watched.join("b.jpg")).unwrap();
    drain(&rx, &root, "③ 同目录内改名 a.jpg → b.jpg");

    std::fs::create_dir_all(watched.join("sub/deep")).unwrap();
    drain(&rx, &root, "④ 新建嵌套目录 sub/deep");

    std::fs::rename(watched.join("b.jpg"), watched.join("sub/deep/b.jpg")).unwrap();
    drain(&rx, &root, "⑤ 移动到子目录（库内分类）");

    std::fs::write(outside.join("c.jpg"), b"ccc").unwrap();
    std::fs::rename(outside.join("c.jpg"), watched.join("c.jpg")).unwrap();
    drain(&rx, &root, "⑥ 从库外拖进来");

    std::fs::rename(watched.join("c.jpg"), outside.join("c.jpg")).unwrap();
    drain(&rx, &root, "⑦ 拖出库外（= Finder 删除进废纸篓）");

    std::fs::remove_file(watched.join("sub/deep/b.jpg")).unwrap();
    drain(&rx, &root, "⑧ 删单个文件");

    for i in 0..5 {
        std::fs::write(watched.join(format!("bulk{i}.jpg")), b"x").unwrap();
    }
    std::fs::remove_dir_all(watched.join("sub")).unwrap();
    drain(&rx, &root, "⑨ 批量写 5 个 + rm -rf 整棵 sub");

    std::fs::remove_dir_all(&watched).unwrap();
    drain(&rx, &root, "⑩ 把被监听的根目录本身删掉");

    std::fs::create_dir_all(&watched).unwrap();
    std::fs::write(watched.join("after.jpg"), b"z").unwrap();
    drain(&rx, &root, "⑪ 重建同名根目录并写入（句柄还活着吗）");
}

/// 被断言锁住的不变量：**被监听的根目录被删掉再重建，事件流不断。**
///
/// WATCH-02 排查时我把「FSEvents 句柄在整棵子树被删后失效」列为最可能的
/// 假设——实测是错的。这条测试把它钉住：如果哪天平台行为真变了，watcher
/// 会在这里先红，而不是在用户的库上静默失效。
#[test]
fn watch_survives_the_root_being_deleted_and_recreated() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let watched = root.join("watched");
    std::fs::create_dir_all(&watched).unwrap();

    let (tx, rx) = mpsc::channel::<Event>();
    let mut w: RecommendedWatcher = notify::recommended_watcher(move |r: notify::Result<Event>| {
        if let Ok(e) = r {
            let _ = tx.send(e);
        }
    })
    .unwrap();
    w.watch(&watched, RecursiveMode::Recursive).unwrap();
    std::thread::sleep(Duration::from_millis(400));

    std::fs::remove_dir_all(&watched).unwrap();
    std::thread::sleep(Duration::from_millis(600));
    while rx.try_recv().is_ok() {} // 清掉删除本身的事件

    std::fs::create_dir_all(&watched).unwrap();
    std::fs::write(watched.join("after.jpg"), b"z").unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut saw = false;
    while std::time::Instant::now() < deadline {
        if let Ok(ev) = rx.recv_timeout(Duration::from_millis(200)) {
            if ev.paths.iter().any(|p| p.ends_with("after.jpg")) {
                saw = true;
                break;
            }
        }
    }
    assert!(saw, "根目录删掉重建后，监听必须还能投递事件");
}
