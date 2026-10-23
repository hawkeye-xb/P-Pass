//! T-070 进程级故障剧本的进程内版本（大文件 / 崩溃恢复 / 磁盘满）。
//!
//! 安全卡 #1115 之后常驻 daemon 不再读 `PPF_DATA_DIR`，`--ephemeral`
//! 也拒绝任何路径输入，原先靠「带 data_dir 起 daemon 二进制、再同目录重启」
//! 的三个 shell 剧本（huge_file.sh / crash_recovery.sh / disk_full.sh）
//! 无法再跑。这里把它们改写成进程内集成测试：同样的备份管线
//! （`BackupEngine` + `Router` + blobs + 真 QUIC 回环），同样的磁盘事实，
//! 「重启」= 在同一个目录上重新打开一套存储端。
//!
//! 三个测试都很重，标 `#[ignore]`，显式运行：
//! `cargo test --release -p daemon --test scenarios -- --ignored --test-threads=1`

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use daemon::{BackupEngine, Router};
use proto::{BackupCommit, BackupItem, BackupManifest, BackupMissing, Req, Resp};
use storage::{Db, Pairing, Role};
use transport::{Blobs, IrohTransport, Transport, TransportConfig};

use crate::common::dir_bytes;

const ALPNS: &[&str] = &["ppf/ctrl/1", "ppf/blobs/1"];
const PAIRING_ID: &str = "pairing-scenario-1";

async fn endpoint() -> IrohTransport {
    IrohTransport::bind(TransportConfig::loopback(
        ALPNS.iter().map(|s| s.to_string()).collect(),
    ))
    .await
    .unwrap()
}

/// `256M` / `2G` / `64K` / 纯字节数。
fn parse_size(raw: &str) -> u64 {
    let raw = raw.trim();
    let (num, mul) = match raw.chars().last() {
        Some('K' | 'k') => (&raw[..raw.len() - 1], 1u64 << 10),
        Some('M' | 'm') => (&raw[..raw.len() - 1], 1u64 << 20),
        Some('G' | 'g') => (&raw[..raw.len() - 1], 1u64 << 30),
        _ => (raw, 1),
    };
    num.parse::<u64>()
        .unwrap_or_else(|_| panic!("无法解析大小 {raw:?}（期望 数字[K|M|G]）"))
        * mul
}

fn env_size(var: &str, default: &str) -> u64 {
    parse_size(&std::env::var(var).unwrap_or_else(|_| default.to_string()))
}

/// 存储端：跑在自己的 tokio runtime + 专用 OS 线程里，这样「崩溃」可以
/// 把整个 runtime 丢掉（不走任何优雅关闭），而测试本身的 runtime 不受影响。
struct Storage {
    addr: transport::PeerAddr,
    node_id: transport::NodeId,
    db: Db,
    stop: mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Storage {
    /// 在 `dir` 上打开（或重新打开）存储端。db / blob store / library 全在 `dir` 下。
    /// 旧实例的 redb 句柄在 runtime 被丢弃后才异步释放，所以打开失败时短暂重试。
    fn open(dir: &Path) -> Storage {
        let mut last = None;
        for attempt in 0..10 {
            match Self::try_open(dir) {
                Ok(s) => return s,
                Err(e) => {
                    eprintln!("   存储端打开失败（第 {attempt} 次）：{e}");
                    last = Some(e);
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
        panic!("存储端无法在 {dir:?} 上打开：{}", last.unwrap());
    }

    fn try_open(dir: &Path) -> Result<Storage, String> {
        let dir = dir.to_path_buf();
        let (ready_tx, ready_rx) = mpsc::channel();
        let (stop_tx, stop_rx) = mpsc::channel::<()>();
        let thread = std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            let started = rt
                .block_on(async {
                    tokio::time::timeout(Duration::from_secs(5), async {
                        let db = Db::open(&dir.join("index.sqlite"))
                            .await
                            .map_err(|e| e.to_string())?;
                        let tp = endpoint().await;
                        let blobs = std::sync::Arc::new(
                            Blobs::open(&tp, &dir.join("daemon-blobs"))
                                .await
                                .map_err(|e| e.to_string())?,
                        );
                        let backup = BackupEngine::new(db.clone(), blobs, dir.join("library"));
                        let router = Router::new(db.clone(), "storage").with_backup(backup);
                        let tp2 = tp.clone();
                        tokio::spawn(async move { router.serve(&tp2).await });
                        Ok::<_, String>((tp.local_addr(), tp.node_id(), db))
                    })
                    .await
                })
                .unwrap_or_else(|_| Err("打开存储端超时（旧实例句柄未释放？）".to_string()));
            let ok = started.is_ok();
            ready_tx.send(started).unwrap();
            if ok {
                // 等「崩溃」信号（或 Storage 被丢弃 = 发送端关闭）。
                let _ = stop_rx.recv();
            }
            // 不优雅：不等任务、不 flush，直接丢掉 runtime。
            rt.shutdown_background();
        });
        match ready_rx.recv().unwrap() {
            Ok((addr, node_id, db)) => Ok(Storage {
                addr,
                node_id,
                db,
                stop: stop_tx,
                thread: Some(thread),
            }),
            Err(e) => {
                let _ = thread.join();
                Err(e)
            }
        }
    }

    /// 模拟进程崩溃：runtime 在传输中途被直接丢弃。
    fn crash(mut self) {
        let _ = self.stop.send(());
        if let Some(t) = self.thread.take() {
            t.join().unwrap();
        }
    }
}

/// 「手机」：经 blobs 提供文件，经 ctrl 说话。存储端重启后 `retarget`。
struct Client {
    tp: IrohTransport,
    blobs: Blobs,
    daemon: std::sync::Mutex<transport::NodeId>,
}

impl Client {
    async fn new(dir: &Path, storage: &Storage) -> Client {
        let tp = endpoint().await;
        tp.add_peer(storage.addr.clone());
        let mut blobs = Blobs::open(&tp, &dir.join("client-blobs")).await.unwrap();
        blobs.serve();
        Client {
            tp,
            blobs,
            daemon: std::sync::Mutex::new(storage.node_id),
        }
    }

    fn retarget(&self, storage: &Storage) {
        self.tp.add_peer(storage.addr.clone());
        *self.daemon.lock().unwrap() = storage.node_id;
    }

    async fn call(&self, method: &str, params: serde_json::Value) -> Result<Resp, String> {
        let daemon = *self.daemon.lock().unwrap();
        let mut stream = self
            .tp
            .connect(daemon, "ppf/ctrl/1")
            .await
            .map_err(|e| format!("connect: {e}"))?;
        let req = Req {
            id: format!("req-{method}"),
            method: method.into(),
            params,
            ..Default::default()
        };
        stream
            .send_frame(&proto::codec::encode(&req).unwrap())
            .await
            .map_err(|e| format!("send: {e}"))?;
        stream.finish().map_err(|e| format!("finish: {e}"))?;
        let frame = stream
            .recv_frame()
            .await
            .map_err(|e| format!("recv: {e}"))?
            .ok_or("no response frame")?;
        Ok(proto::codec::decode::<Resp>(&frame).unwrap())
    }

    /// 一轮完整备份。`Ok(missing)` = commit 成功；`Err` = 某一步失败（含 commit 失败）。
    async fn try_backup(&self, items: &[BackupItem]) -> Result<usize, String> {
        let r = self.call("backup.begin", serde_json::Value::Null).await?;
        if !r.ok {
            return Err(format!("backup.begin: {r:?}"));
        }
        let manifest = BackupManifest {
            hashes: vec![],
            items: items.to_vec(),
            provider: Some(self.tp.local_addr().to_string()),
        };
        let r = self
            .call("backup.manifest", serde_json::to_value(&manifest).unwrap())
            .await?;
        if !r.ok {
            return Err(format!("backup.manifest: {r:?}"));
        }
        let missing: BackupMissing = serde_json::from_value(r.result.unwrap()).unwrap();
        let r = self
            .call(
                "backup.commit",
                serde_json::to_value(&BackupCommit {
                    generation: Some(items.len() as i64),
                })
                .unwrap(),
            )
            .await?;
        if !r.ok {
            return Err(format!("backup.commit: {r:?}"));
        }
        Ok(missing.hashes.len())
    }

    async fn backup(&self, items: &[BackupItem]) -> usize {
        self.try_backup(items)
            .await
            .unwrap_or_else(|e| panic!("备份应成功：{e}"))
    }

    /// 把 `path` 登记进手机端 blob store（流式哈希，不整读入内存）并返回清单条目。
    async fn import_file(&self, path: &Path) -> BackupItem {
        let mut f = fs::File::open(path).unwrap();
        let mut hasher = blake3::Hasher::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = f.read(&mut buf).unwrap();
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let hash = *hasher.finalize().as_bytes();
        self.blobs.import(hash, path).await.unwrap();
        BackupItem {
            hash: hash.iter().map(|b| format!("{b:02x}")).collect(),
            file_name: path.file_name().unwrap().to_string_lossy().into_owned(),
            media_type: "image/jpeg".into(),
        }
    }
}

async fn pair(storage: &Storage, client: &Client) {
    storage
        .db
        .accept_pairing(
            &client.tp.node_id().0,
            "phone",
            &Pairing {
                id: PAIRING_ID.into(),
                node_id: client.tp.node_id().0.to_vec(),
                role: Role::Member,
                paired_at: 1,
            },
        )
        .await
        .unwrap();
}

/// 稀疏文件：逻辑大小 `size`，实际磁盘 ~0（全零内容 → hash 跨运行确定）。
fn sparse_file(dir: &Path, name: &str, size: u64) -> PathBuf {
    let path = dir.join(name);
    fs::File::create(&path).unwrap().set_len(size).unwrap();
    path
}

fn find_file(root: &Path, name: &str) -> Option<PathBuf> {
    for entry in fs::read_dir(root).ok()?.flatten() {
        let p = entry.path();
        if p.is_dir() {
            if let Some(found) = find_file(&p, name) {
                return Some(found);
            }
        } else if p.file_name().is_some_and(|n| n == name) {
            return Some(p);
        }
    }
    None
}

/// 取代 tools/scenarios/huge_file.sh。
///
/// 证明：单个大文件（默认 256M，`PPF_SCENARIO_SIZE` 可调到 4G）走完整备份
/// 管线（手机 blob 提供 → 存储端拉取 → 入库落 originals/），落盘逻辑大小
/// 与源文件逐字节一致；幂等重跑存储端缺 0 个。稀疏文件控制 CI 时长，
/// 峰值磁盘约 3×size（blob store + staging + originals）。
///
/// 反证：把落盘大小断言的期望值改成 `size + 1`，或让重跑的期望缺失数改成 1，
/// 本测试必须红（落盘 = 源文件、重跑 = 0 是两条独立的真实断言）。
#[test]
#[ignore = "heavy: cargo test --release -p daemon --test scenarios -- --ignored --test-threads=1"]
fn huge_file_lands_with_exact_size_and_rerun_is_idempotent() {
    let size = env_size("PPF_SCENARIO_SIZE", "256M");
    eprintln!("==> 大文件剧本：{size} 字节（稀疏文件，峰值磁盘 ~3×size）");
    let dir = tempfile::tempdir().unwrap();
    let storage = Storage::open(dir.path());
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async {
        let client = Client::new(dir.path(), &storage).await;
        pair(&storage, &client).await;
        let src = dir.path().join("src");
        fs::create_dir_all(&src).unwrap();
        let item = client
            .import_file(&sparse_file(&src, "BIG_0000.bin", size))
            .await;

        let started = Instant::now();
        let missing = client.backup(std::slice::from_ref(&item)).await;
        eprintln!("   耗时 {:?}", started.elapsed());
        assert_eq!(missing, 1, "首跑：这一个大文件就是缺的那一个");

        let landed = find_file(&dir.path().join("library/originals"), "BIG_0000.bin")
            .expect("大文件必须落到 library/originals");
        assert_eq!(
            fs::metadata(&landed).unwrap().len(),
            size,
            "落盘逻辑大小必须等于源文件"
        );

        let missing = client.backup(std::slice::from_ref(&item)).await;
        assert_eq!(missing, 0, "幂等重跑应缺 0");
    });
    storage.crash();
}

/// 取代 tools/scenarios/crash_recovery.sh。
///
/// 证明：备份传输进行中存储端崩溃，在**同一目录**上重开一套存储端后，
/// 重跑备份收敛（missing 按当前索引现算：恰好补收 1 个 blob）、再跑缺 0、
/// 原件落在 library/originals。即崩溃安全与「索引可重建」语义。
///
/// 注意：这是**进程内崩溃**（传输中途直接 `shutdown_background()` 丢掉存储端
/// 的整个 runtime，不走任何优雅关闭），不是 SIGKILL。它仍覆盖该性质：被验证的
/// 是「在被打断的磁盘状态（半截 blob / staging）之上重启」，而不是进程信号本身；
/// 进程被杀与 runtime 被丢弃留给磁盘的是同一类状态（没有 flush、没有收尾）。
/// 「传输已开始」的信号与旧脚本一致：blob store 目录字节数较基线增长 ≥1MB，
/// 不靠 sleep 赌时序；若崩溃时备份已跑完则直接失败（调大 `PPF_SCENARIO_SIZE_CRASH`）。
///
/// 反证：把重启后首轮重跑的期望新增 blob 数从 1 改成 0，本测试必须红。
#[test]
#[ignore = "heavy: cargo test --release -p daemon --test scenarios -- --ignored --test-threads=1"]
fn crash_mid_transfer_restart_converges_on_same_dir() {
    let size = env_size("PPF_SCENARIO_SIZE_CRASH", "128M");
    let dir = tempfile::tempdir().unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();

    let storage = Storage::open(dir.path());
    let (client, item, in_flight) = rt.block_on(async {
        let client = std::sync::Arc::new(Client::new(dir.path(), &storage).await);
        pair(&storage, &client).await;
        let src = dir.path().join("src");
        fs::create_dir_all(&src).unwrap();
        let item = client
            .import_file(&sparse_file(&src, "BIG_0000.bin", size))
            .await;

        let blobs_dir = dir.path().join("daemon-blobs");
        let base = dir_bytes(&blobs_dir);
        // 传输在后台跑；崩溃后它会失败或悬挂，之后直接 abort。
        let task = {
            let c = client.clone();
            let items = vec![item.clone()];
            tokio::spawn(async move { c.try_backup(&items).await })
        };
        let deadline = Instant::now() + Duration::from_secs(30);
        while dir_bytes(&blobs_dir).saturating_sub(base) < 1 << 20 {
            assert!(
                !task.is_finished(),
                "崩溃前备份已结束——传输太快，调大 PPF_SCENARIO_SIZE_CRASH"
            );
            assert!(
                Instant::now() < deadline,
                "30s 内 blob store 无明显增长（基线 {base}B）——传输未开始就崩溃会让剧本失去意义"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        eprintln!(
            "   传输进行中（blob store {base}B -> {}B），崩溃存储端",
            dir_bytes(&blobs_dir)
        );
        (client, item, task)
    });

    storage.crash();
    in_flight.abort();
    rt.block_on(async {
        let _ = in_flight.await;
        // 同一目录重启 → 同一索引、同一 blob store。
        let storage = Storage::open(dir.path());
        client.retarget(&storage);

        let missing = client.backup(std::slice::from_ref(&item)).await;
        assert_eq!(missing, 1, "重启后重跑应补齐缺失（恰好 1 个新 blob）");
        let missing = client.backup(std::slice::from_ref(&item)).await;
        assert_eq!(missing, 0, "收敛后再跑应缺 0");

        let landed = find_file(&dir.path().join("library/originals"), "BIG_0000.bin")
            .expect("原件必须落在 library/originals");
        assert_eq!(fs::metadata(&landed).unwrap().len(), size);
        storage.crash();
    });
}

/// 取代 tools/scenarios/disk_full.sh。
///
/// 只在 `PPF_SCENARIO_SMALL_FS` 指向一个已存在的目录（该目录必须在小文件系统上，
/// CI 挂 6MB tmpfs）时运行，否则打印 SKIP 并返回——小文件系统需要 root mount，
/// 不能由测试自己造。存储端的 db / blob store / library 整个放在该目录下。
///
/// 证明：先成功备份 1 个小文件（已入库数据）；再备份约 8MB（500 x 16KB，
/// 放不下）→ 备份必须失败（退出码 0 = 故障没触发 = 假绿）；文件系统使用率
/// 确实 >= 90%（物理证据，iroh-blobs 会把 ENOSPC 包装成别的文案，错误文本
/// 不可依赖）；存储端仍应答 ctrl 请求（无 panic、无死任务）；已入库数据完好。
///
/// 「恢复」步骤：旧脚本是换 64MB 重挂载同路径重启。进程内无法重挂载，改为：
/// 关停存储端 -> 把整个目录（含磁盘满留下的残留）复制到一个大得多的临时目录 ->
/// 在副本上重开存储端 -> 同一份 500 文件重跑必须收敛、再跑缺 0、此前入库的
/// 原件内容不变。等价于「同一份磁盘状态、空间恢复后干净重启并服务」。
///
/// 反证：把 `PPF_SCENARIO_SMALL_FS` 指到大磁盘，故障不触发，「备份必须失败」
/// 断言会红；把使用率阈值调到 100 同样会红。
#[test]
#[ignore = "heavy: needs PPF_SCENARIO_SMALL_FS on a ~6MB filesystem"]
fn disk_full_fails_gracefully_and_recovers_with_space() {
    let Some(small) = std::env::var_os("PPF_SCENARIO_SMALL_FS").map(PathBuf::from) else {
        eprintln!("DISK FULL SCENARIO: SKIP (未设置 PPF_SCENARIO_SMALL_FS——需要一个挂在小文件系统上的目录)");
        return;
    };
    assert!(
        small.is_dir(),
        "PPF_SCENARIO_SMALL_FS 必须是已存在的目录：{small:?}"
    );
    let store = small.join(format!("ppf-diskfull-{}", std::process::id()));
    let _ = fs::remove_dir_all(&store);
    fs::create_dir_all(&store).unwrap();
    let work = tempfile::tempdir().unwrap(); // 手机端文件放在正常磁盘上
    let rt = tokio::runtime::Runtime::new().unwrap();

    let storage = Storage::open(&store);
    let (client, small_item, items) = rt.block_on(async {
        let client = Client::new(work.path(), &storage).await;
        pair(&storage, &client).await;
        let src = work.path().join("src");
        fs::create_dir_all(&src).unwrap();

        // 磁盘满之前已入库的数据。
        let first = src.join("BEFORE_0000.jpg");
        fs::write(&first, vec![0xA5u8; 4096]).unwrap();
        let small_item = client.import_file(&first).await;
        assert_eq!(client.backup(std::slice::from_ref(&small_item)).await, 1);

        // 500 x ~16KB 互不相同的文件 ≈ 8MB > 6MB。
        let mut s: u64 = 0x5EED_2026_0730_0005;
        let mut items = vec![small_item.clone()];
        for i in 0..500u32 {
            let mut v = i.to_le_bytes().to_vec();
            for _ in 0..2048 {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                v.extend_from_slice(&s.to_le_bytes());
            }
            let p = src.join(format!("IMG_{i:04}.jpg"));
            fs::write(&p, v).unwrap();
            items.push(client.import_file(&p).await);
        }

        let err = client
            .try_backup(&items)
            .await
            .expect_err("磁盘满但备份竟然成功——故障未触发（payload 可能放得下），判据失效");
        eprintln!("   备份按预期失败：{err}");

        let used = used_percent(&store);
        assert!(
            used >= 90,
            "文件系统使用率仅 {used}%——磁盘没有真的被填满，故障未命中"
        );
        eprintln!("   磁盘满故障已实证（使用率 {used}%）");

        // 存储端仍应答（成功或带错误的响应都算活着；连不上/悬挂才是死）。
        let resp = tokio::time::timeout(
            Duration::from_secs(30),
            client.call("backup.begin", serde_json::Value::Null),
        )
        .await
        .expect("磁盘满后存储端 ctrl 无响应（死任务）")
        .expect("磁盘满后存储端必须仍能应答 ctrl 请求");
        eprintln!("   存储端仍应答 ctrl（ok={}）", resp.ok);
        (client, small_item, items)
    });
    let _ = &small_item;

    // 已入库数据完好：磁盘满之前的那个原件还在、内容未变。
    let kept = find_file(&store.join("library/originals"), "BEFORE_0000.jpg")
        .expect("磁盘满之前已入库的原件必须仍在");
    assert_eq!(fs::read(&kept).unwrap(), vec![0xA5u8; 4096]);

    // 「恢复」：停存储端 -> 连同残留搬到大目录 -> 重开 -> 收敛。
    storage.crash();
    let big = tempfile::tempdir().unwrap();
    copy_dir(&store, big.path());
    rt.block_on(async {
        let storage = Storage::open(big.path());
        client.retarget(&storage);
        client.backup(&items).await;
        assert_eq!(client.backup(&items).await, 0, "空间恢复并收敛后再跑应缺 0");
        storage.crash();
    });
    let kept = find_file(&big.path().join("library/originals"), "BEFORE_0000.jpg")
        .expect("恢复后此前入库的原件必须仍在");
    assert_eq!(fs::read(&kept).unwrap(), vec![0xA5u8; 4096]);
    let _ = fs::remove_dir_all(&store);
}

/// `df` 的使用率百分比（Linux/macOS 通用的 POSIX 输出）。
// 仅测试脚手架、仅 Linux/macOS（小文件系统要 root mount，本就没有 Windows 版）：
// 无 GUI 进程，不需要 platform::command 的 CREATE_NO_WINDOW。
#[allow(clippy::disallowed_methods)]
fn used_percent(path: &Path) -> u32 {
    let out = std::process::Command::new("df")
        .arg("-P")
        .arg(path)
        .output()
        .expect("df");
    let text = String::from_utf8_lossy(&out.stdout);
    text.lines()
        .nth(1)
        .and_then(|l| l.split_whitespace().nth(4))
        .and_then(|p| p.trim_end_matches('%').parse().ok())
        .unwrap_or_else(|| panic!("无法解析 df 输出：{text}"))
}

fn copy_dir(from: &Path, to: &Path) {
    for entry in fs::read_dir(from).unwrap().flatten() {
        let dest = to.join(entry.file_name());
        if entry.path().is_dir() {
            fs::create_dir_all(&dest).unwrap();
            copy_dir(&entry.path(), &dest);
        } else {
            fs::copy(entry.path(), &dest).unwrap();
        }
    }
}
