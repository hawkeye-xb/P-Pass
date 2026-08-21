//! Upload plane (T-054): the phone pushes file bytes over
//! `ppf/upload/1`, one file per bidirectional stream — an
//! [`UploadHeader`] frame, then raw bytes, then a [`Resp`] frame back.
//!
//! Security shape: this is a GATED push. Every connection passes the
//! same authz checkpoint as the ctrl plane (pseudo-method
//! `backup.upload`, granted to member+ via the `backup.` prefix). The
//! received bytes must hash to the declared BLAKE3 before the blob
//! store accepts them — a lying uploader gets an error, not storage.

use std::path::PathBuf;

use proto::msgs::{methods, UploadHeader};
use proto::{codes, Req, Resp, RespError};
use storage::Db;
use transport::Incoming;

use crate::authz;

/// Upper bound per file — matches the design's "4 GB video" hardening
/// scenario (T-070 exercises the edge).
const MAX_UPLOAD_BYTES: u64 = 8 * 1024 * 1024 * 1024;

#[derive(Clone)]
pub struct UploadPlane {
    db: Db,
    /// MOB-30：收完一张就入库，不再攒到 `backup.commit`。
    /// 拿 engine 而不是自己持有 Ingestor：单条入库的实现只能有一份
    /// （`BackupEngine::ingest_one`），各写一遍必然漂移。
    engine: crate::BackupEngine,
    // BLOB-01: 上传平面不再碰 blob store（校验自己做，文件留 staging 等
    // ingest）。字段保留但不用会被 clippy 顶回来，所以直接去掉——回退路径
    // （T-032 主动拉取）的 blob store 由 BackupEngine 持有。
    staging: PathBuf,
}

impl UploadPlane {
    pub fn new(db: Db, staging: PathBuf, engine: crate::BackupEngine) -> Self {
        Self {
            db,
            engine,
            staging,
        }
    }

    /// Serve one upload connection: streams arrive sequentially, one
    /// file each. Authz is checked per stream (revocation mid-batch
    /// slams the door on the next file).
    pub async fn serve_conn(&self, conn: Incoming) {
        let peer = conn.peer();
        loop {
            let Ok(mut stream) = conn.accept_bi().await else {
                return;
            };
            let plane = self.clone();
            if !plane.serve_stream(peer, &mut stream).await {
                return;
            }
        }
    }

    async fn serve_stream(
        &self,
        peer: transport::NodeId,
        stream: &mut transport::BiStream,
    ) -> bool {
        // ── Authz checkpoint (same gate as ctrl) ──
        let device = match self.db.get_device(&peer.0).await {
            Ok(d) => d,
            Err(_) => return false,
        };
        if let authz::Decision::Deny { msg_key } =
            authz::check(device.as_ref(), methods::BACKUP_UPLOAD)
        {
            let resp = Resp::err(
                String::new(),
                RespError::new(codes::NOT_AUTHORIZED, msg_key),
            );
            let _ = self.send(stream, &resp).await;
            return false;
        }

        // ── Header frame ──
        let header: UploadHeader = match stream.recv_frame().await {
            Ok(Some(frame)) => match proto::codec::decode::<Req>(&frame) {
                // The phone wraps the header in the Req envelope so the
                // stream opens with the same shape as every other plane.
                Ok(req) => match serde_json::from_value(req.params) {
                    Ok(h) => h,
                    Err(_) => return self.reject(stream, "err.unsupported").await,
                },
                Err(_) => return self.reject(stream, "err.unsupported").await,
            },
            _ => return false, // clean finish or broken stream
        };
        if header.bytes > MAX_UPLOAD_BYTES || header.hash.len() != 64 {
            return self.reject(stream, "err.unsupported").await;
        }

        // ── Raw bytes → staging file (streamed, never in memory) ──
        std::fs::create_dir_all(&self.staging).ok();
        let staged = self.staging.join(format!("{}.upload", header.hash));
        let outcome = self.receive_file(stream, &header, &staged).await;

        match outcome {
            Ok(()) => {
                // MOB-30：收完一张**立刻入库**，不攒到 commit。
                // 用户定调：「上传是主动的，我觉得入库也应该是主动的。」
                //
                // 失败不让这条流失败——文件已校验落在 staging 里，`commit`
                // 会兜底重试；把 ACK 变成错误只会让手机把这张重传一遍。
                // 但必须留日志（别静默吞）。
                if let Err(e) = self.engine.ingest_staged(peer, &header.hash).await {
                    tracing::warn!(
                        "upload {}: 即时入库失败，留给 commit 兜底: {e}",
                        header.hash
                    );
                }
                let resp = Resp::ok(String::new(), serde_json::json!({"stored": header.hash}));
                let _ = self.send(stream, &resp).await;
                true
            }
            Err(msg_key) => {
                let _ = std::fs::remove_file(&staged);
                self.reject(stream, msg_key).await
            }
        }
    }

    /// Stream bytes to disk, verify BLAKE3, then rename it ready for ingest.
    async fn receive_file(
        &self,
        stream: &mut transport::BiStream,
        header: &UploadHeader,
        staged: &std::path::Path,
    ) -> Result<(), &'static str> {
        use std::io::Write;
        let mut file = std::fs::File::create(staged).map_err(|_| "err.internal")?;
        let mut hasher = blake3::Hasher::new();
        let mut received: u64 = 0;
        loop {
            match stream.recv_chunk(256 * 1024).await {
                Ok(Some(chunk)) => {
                    received += chunk.len() as u64;
                    if received > header.bytes {
                        return Err("err.unsupported"); // more than declared
                    }
                    hasher.update(&chunk);
                    file.write_all(&chunk).map_err(|_| "err.internal")?;
                }
                Ok(None) => break,
                Err(_) => return Err("err.internal"),
            }
        }
        file.flush().map_err(|_| "err.internal")?;
        drop(file);

        if received != header.bytes {
            tracing::warn!(
                "upload {}: declared {} bytes, received {received}",
                header.hash,
                header.bytes
            );
            return Err("err.unsupported");
        }
        let got = hasher.finalize();
        let Some(expected) = parse_hash(&header.hash) else {
            return Err("err.unsupported");
        };
        if got.as_bytes() != &expected {
            tracing::warn!("upload {}: content hash mismatch", header.hash);
            return Err("err.unsupported");
        }

        // ── BLOB-01（2026-08-20）：不再往 blob store 拷一份 ──
        //
        // 旧实现在这里 `blobs.push(expected, staged)` 然后删掉 staged。
        // 那是同一份字节的**第二次全文件拷贝**（`add_path` 的默认导入模式
        // 是 `ImportMode::Copy`），而 commit 阶段又要 `export_to` 把它**拷
        // 第三次**回 staging 才能 ingest。用户机器实测的后果：
        //
        //   originals   549M   ← 照片库（真正要留的）
        //   .ppf/blobs  554M   ← 同一批照片在收件箱里的第二份，永不回收
        //   合计        1.1G   → 占盘 = 照片本身的 2.05 倍
        //
        // blob store 在这条路径上唯一的作用是"边收边验"，而**上面这段代码
        // 已经自己做完了**：流式写盘 + 边写边算 BLAKE3 + 自己比对，不匹配
        // 直接 reject。所以那一圈纯属多余往返。
        //
        // 用户定调："收到文件，文件都已经保存好了，我们就没必要在收件箱里面
        // 保留这个文件了吧……它的独立功能就只有一项，一个是收件，一个是中转。"
        //
        // 现在改成**原地改名坐实**：`<hash>.upload` → `<hash>`。
        // 后缀就是完整性契约——带 `.upload` = 还在写/没验过，不带 = 校验通过
        // 可以 ingest。同目录 rename 是原子的，不存在"改了一半"的中间态。
        //
        // 续传能力零损失：上传协议本来就没有 offset/resume 字段
        // （`UploadHeader` 只有 hash/bytes/file_name），`File::create` 直接
        // 截断——断了从来都是整个文件重传，不是本卡丢的。
        let ready = self.staging.join(&header.hash);
        std::fs::rename(staged, &ready).map_err(|_| "err.internal")?;
        tracing::info!(
            "upload accepted: {} ({} bytes, {})",
            header.hash,
            header.bytes,
            header.file_name
        );
        Ok(())
    }

    async fn reject(&self, stream: &mut transport::BiStream, msg_key: &'static str) -> bool {
        let resp = Resp::err(
            String::new(),
            RespError::new(codes::INVALID_REQUEST, msg_key),
        );
        let _ = self.send(stream, &resp).await;
        false
    }

    async fn send(&self, stream: &mut transport::BiStream, resp: &Resp) -> bool {
        match proto::codec::encode(resp) {
            Ok(frame) => stream.send_frame(&frame).await.is_ok(),
            Err(_) => false,
        }
    }
}

fn parse_hash(hex: &str) -> Option<[u8; 32]> {
    if hex.len() != 64 {
        return None;
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        out[i] = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(out)
}
