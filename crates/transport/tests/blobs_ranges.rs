//! #851: ranged fetch — only the requested byte ranges (widened to 16 KiB groups) plus the last
//! chunk travel, every byte verified against the root hash, and the total size comes back verified.

use std::fs;
use std::time::Duration;

use transport::{Blobs, IrohTransport, TransportConfig};

const LEN: usize = 1024 * 1024 + 123; // not a multiple of the group size: the last group is short

fn payload() -> Vec<u8> {
    let mut v = Vec::with_capacity(LEN);
    let mut s: u64 = 0x8510_2026_1012_0001;
    while v.len() < LEN {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.extend_from_slice(&s.to_le_bytes());
    }
    v.truncate(LEN);
    v
}

fn covers(pieces: &[(u64, Vec<u8>)], data: &[u8], r: std::ops::Range<u64>) -> bool {
    pieces.iter().any(|(off, buf)| {
        *off <= r.start
            && r.end <= off + buf.len() as u64
            && buf[(r.start - off) as usize..(r.end - off) as usize]
                == data[r.start as usize..r.end as usize]
    })
}

#[tokio::test(flavor = "multi_thread")]
async fn ranged_fetch_moves_only_the_requested_groups_and_verifies_them() {
    let dir = tempfile::tempdir().unwrap();
    let tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let data = payload();
    let src = dir.path().join("original.bin");
    fs::write(&src, &data).unwrap();
    let hash = *blake3::hash(&data).as_bytes();
    let mut provider = Blobs::open(&tp, &dir.path().join("provider-store"))
        .await
        .unwrap();
    provider.serve();
    let ticket = provider.push(hash, &src).await.unwrap();

    let rx_tp = IrohTransport::bind(TransportConfig::loopback(
        vec![transport::ALPN_BLOBS.into()],
    ))
    .await
    .unwrap();
    let rx = Blobs::open(&rx_tp, &dir.path().join("rx-store"))
        .await
        .unwrap();
    let (peer, ticket_hash) = rx.register_blob_ticket(&ticket).unwrap();
    assert_eq!(ticket_hash, hash);

    // A JPEG-style header range and an MP4-style tail range.
    let head = 100..300u64;
    let tail = (LEN as u64 - 40)..(LEN as u64 - 10);
    let (size, pieces) = rx
        .fetch_byte_ranges(
            peer,
            hash,
            &[head.clone(), tail.clone()],
            Duration::from_secs(20),
        )
        .await
        .unwrap();

    assert_eq!(size, LEN as u64, "verified total size");
    assert!(
        covers(&pieces, &data, head),
        "header range present and byte-identical"
    );
    assert!(
        covers(&pieces, &data, tail),
        "tail range present and byte-identical"
    );
    let fetched: u64 = pieces.iter().map(|(_, b)| b.len() as u64).sum();
    assert!(
        fetched <= 2 * 16 * 1024,
        "only two 16 KiB groups exported, got {fetched}"
    );
    let local = rx.local_bytes(hash).await.unwrap();
    assert!(
        local < LEN as u64 / 4,
        "the receiver must not have pulled the whole blob ({local} bytes local)"
    );

    rx.close().await;
    provider.close().await;
    rx_tp.close().await;
    tp.close().await;
}
