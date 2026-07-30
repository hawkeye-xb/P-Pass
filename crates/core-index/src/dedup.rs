//! Content-hash dedup. BLAKE3 is the asset primary key (same hash domain
//! as iroh-blobs, 架构 §4.2), so "same photo from two phones" is one row.

use std::fs::File;
use std::io::Read;
use std::path::Path;

use crate::{IndexError, Result};

/// Streaming BLAKE3 of a file — 64 KiB chunks, constant memory, so a 4 GB
/// video costs the same RAM as a thumbnail.
pub fn hash_file(path: &Path) -> Result<[u8; 32]> {
    let io_err = |source| IndexError::Io {
        path: path.to_path_buf(),
        source,
    };
    let mut f = File::open(path).map_err(io_err)?;
    let mut hasher = blake3::Hasher::new();
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(io_err)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(*hasher.finalize().as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_matches_reference_over_chunk_boundaries() {
        // 3 MiB spans many 64 KiB read chunks; must equal one-shot blake3.
        let data: Vec<u8> = (0..3 * 1024 * 1024u32).map(|i| (i % 251) as u8).collect();
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("big.bin");
        std::fs::write(&p, &data).unwrap();
        assert_eq!(hash_file(&p).unwrap(), *blake3::hash(&data).as_bytes());
    }

    #[test]
    fn empty_file_hashes_like_empty_input() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("empty");
        std::fs::write(&p, b"").unwrap();
        assert_eq!(hash_file(&p).unwrap(), *blake3::hash(b"").as_bytes());
    }

    #[test]
    fn missing_file_error_names_the_path() {
        let msg = hash_file(Path::new("/no/such/dir/x.jpg"))
            .unwrap_err()
            .to_string();
        assert!(
            msg.contains("/no/such/dir/x.jpg"),
            "error must name the path: {msg}"
        );
    }
}
