//! #1306：`Blobs::export_to` 只在内容完整、落盘之后才让最终名字出现。
//!
//! iroh-blobs 的导出直接写目标路径；中途失败（磁盘满、进程被杀）会在最终名下
//! 留半截文件，而调用方（`backup.commit` 等）把「`<hash>` 这个名字存在」当成
//! 「完整」。这里钉住两条契约：
//! - 成功：目标文件内容完整，临时名不留；
//! - 失败：既不出现目标文件，也不留临时名。
//!
//! 前两条在普通磁盘上跑（不存在的 hash 在 store 层就报错、还没碰目标文件，
//! 所以它们只钉住「不留临时名、不凭空造文件」，区分不了直写与改名）。真正
//! 的判别是第三条：在小文件系统上导出放不下的 blob，必须既没有目标文件、也
//! 没有临时名。它和 T-070 磁盘满剧本一样只在 `PPF_SCENARIO_SMALL_FS` 指向一个
//! 小文件系统上的目录时跑，否则打印 SKIP。反证：把 `export_to` 改回直接导出
//! 到 `dest`，第三条红（目标名下留着半截文件）。

use std::fs;

use transport::{export_temp_path, Blobs, IrohTransport, TransportConfig};

async fn store(dir: &std::path::Path) -> (IrohTransport, Blobs) {
    let tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let blobs = Blobs::open(&tp, &dir.join("store")).await.unwrap();
    (tp, blobs)
}

#[tokio::test]
async fn a_finished_export_lands_whole_and_leaves_no_temp_name() {
    let dir = tempfile::tempdir().unwrap();
    let (_tp, blobs) = store(dir.path()).await;
    let data: Vec<u8> = (0..16_388u32).map(|i| (i % 251) as u8).collect();
    let src = dir.path().join("src.bin");
    fs::write(&src, &data).unwrap();
    let hash = *blake3::hash(&data).as_bytes();
    blobs.import(hash, &src).await.unwrap();

    let dest = dir.path().join("out").join(hex(&hash));
    fs::create_dir_all(dest.parent().unwrap()).unwrap();
    blobs.export_to(hash, &dest).await.unwrap();

    assert_eq!(fs::read(&dest).unwrap(), data);
    assert!(
        !export_temp_path(&dest).exists(),
        "完成后临时名必须已改名走"
    );
}

#[tokio::test]
async fn a_failed_export_never_creates_or_clobbers_the_final_name() {
    let dir = tempfile::tempdir().unwrap();
    let (_tp, blobs) = store(dir.path()).await;
    let missing = [0x7Au8; 32]; // 不在 store 里：导出必然失败

    // 目标名下已有一份内容（例如上一轮导出成功的成品）：失败的导出不许碰它。
    let dest = dir.path().join(hex(&missing));
    fs::write(&dest, b"earlier complete copy").unwrap();
    assert!(blobs.export_to(missing, &dest).await.is_err());
    assert_eq!(fs::read(&dest).unwrap(), b"earlier complete copy");
    assert!(!export_temp_path(&dest).exists(), "失败后临时名必须清掉");

    // 目标名下什么都没有：失败后也不该凭空出现一个。
    let fresh = dir.path().join("fresh");
    assert!(blobs.export_to(missing, &fresh).await.is_err());
    assert!(!fresh.exists());
    assert!(!export_temp_path(&fresh).exists());
}

#[tokio::test]
async fn an_export_cut_short_by_a_full_disk_leaves_no_file_under_the_final_name() {
    let Some(small) = std::env::var_os("PPF_SCENARIO_SMALL_FS").map(std::path::PathBuf::from)
    else {
        eprintln!(
            "EXPORT DISK FULL: SKIP (未设置 PPF_SCENARIO_SMALL_FS——需要一个挂在小文件系统上的目录)"
        );
        return;
    };
    let dir = tempfile::tempdir().unwrap(); // store 在正常磁盘上
    let (_tp, blobs) = store(dir.path()).await;
    // 比小文件系统（约 6MB）大：导出必然在中途撞上 ENOSPC。
    let data: Vec<u8> = (0..16u32 << 20)
        .map(|i| (i.wrapping_mul(2_654_435_761) >> 24) as u8)
        .collect();
    let src = dir.path().join("big.bin");
    fs::write(&src, &data).unwrap();
    let hash = *blake3::hash(&data).as_bytes();
    blobs.import(hash, &src).await.unwrap();

    let out = small.join(format!("ppf-export-{}", std::process::id()));
    fs::create_dir_all(&out).unwrap();
    let dest = out.join(hex(&hash));
    let res = blobs.export_to(hash, &dest).await;
    let leftovers: Vec<_> = fs::read_dir(&out)
        .unwrap()
        .flatten()
        .map(|e| (e.file_name(), e.metadata().map(|m| m.len()).unwrap_or(0)))
        .collect();
    let _ = fs::remove_dir_all(&out);
    assert!(
        res.is_err(),
        "放不下却导出成功——小文件系统没起作用，判据失效"
    );
    assert!(
        leftovers.is_empty(),
        "磁盘满中断的导出不许在目录里留任何东西（尤其是最终名下的半截文件）：{leftovers:?}"
    );
}

fn hex(h: &[u8; 32]) -> String {
    h.iter().map(|b| format!("{b:02x}")).collect()
}
