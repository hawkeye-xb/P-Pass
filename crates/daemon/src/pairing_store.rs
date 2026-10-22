//! #1115：配对记录正本放在平台的安全存储里（macOS 钥匙串），库里只留镜像。
//!
//! 平台端口只管存取一份字节（`platform::SecretBlobStore`），这里负责格式；镜像对齐、
//! 写入顺序与崩溃收敛在 `storage`（`pairing_vault.rs`）。
//!
//! 格式：`{"version":1,"pairings":[{"id","node_id"(hex),"role","paired_at"}]}`。
//! 每次写入都是整份读-改-写（storage 那边的写入已串行）。内容读不懂 ⇒ `Err`，
//! daemon 拒绝启动——绝不当成空白名单（那等于静默撤销全部设备）。

use serde::{Deserialize, Serialize};
use storage::{Pairing, PairingVault, Role};

const FORMAT_VERSION: u32 = 1;

#[derive(Serialize, Deserialize)]
struct Doc {
    version: u32,
    pairings: Vec<Entry>,
}

#[derive(Serialize, Deserialize)]
struct Entry {
    id: String,
    node_id: String,
    role: String,
    paired_at: i64,
}

/// 用一份 [`platform::SecretBlobStore`] 存配对记录。
pub struct SecretPairingVault {
    store: Box<dyn platform::SecretBlobStore>,
}

impl SecretPairingVault {
    pub fn new(store: Box<dyn platform::SecretBlobStore>) -> Self {
        Self { store }
    }

    fn read(&self) -> Result<Vec<Pairing>, String> {
        match self.store.read().map_err(|e| e.to_string())? {
            None => Ok(Vec::new()),
            Some(bytes) => decode(&bytes),
        }
    }

    fn write(&self, all: &[Pairing]) -> Result<(), String> {
        self.store.write(&encode(all)).map_err(|e| e.to_string())
    }
}

impl PairingVault for SecretPairingVault {
    fn load_all(&self) -> Result<Vec<Pairing>, String> {
        self.read()
    }

    fn insert(&self, pairing: &Pairing) -> Result<(), String> {
        let mut all = self.read()?;
        all.retain(|p| p.node_id != pairing.node_id);
        all.push(pairing.clone());
        self.write(&all)
    }

    fn delete(&self, node_id: &[u8]) -> Result<(), String> {
        let mut all = self.read()?;
        let before = all.len();
        all.retain(|p| p.node_id != node_id);
        if all.len() == before {
            return Ok(());
        }
        self.write(&all)
    }

    fn delete_all(&self) -> Result<(), String> {
        self.store.delete().map_err(|e| e.to_string())
    }

    fn location(&self) -> String {
        self.store.location()
    }
}

fn encode(all: &[Pairing]) -> Vec<u8> {
    let doc = Doc {
        version: FORMAT_VERSION,
        pairings: all
            .iter()
            .map(|p| Entry {
                id: p.id.clone(),
                node_id: p.node_id.iter().map(|b| format!("{b:02x}")).collect(),
                role: p.role.as_str().to_string(),
                paired_at: p.paired_at,
            })
            .collect(),
    };
    serde_json::to_vec(&doc).expect("配对记录序列化不会失败")
}

fn decode(bytes: &[u8]) -> Result<Vec<Pairing>, String> {
    let doc: Doc = serde_json::from_slice(bytes).map_err(|e| format!("配对记录正本读不懂：{e}"))?;
    if doc.version != FORMAT_VERSION {
        return Err(format!("配对记录正本格式版本 {} 不认识", doc.version));
    }
    doc.pairings
        .into_iter()
        .map(|e| {
            let node_id = parse_hex(&e.node_id)
                .filter(|b| b.len() == 32)
                .ok_or_else(|| format!("配对记录 {} 的 node_id 不合法", e.id))?;
            let role = match e.role.as_str() {
                "member" => Role::Member,
                "viewer" => Role::Viewer,
                other => return Err(format!("配对记录 {} 的角色 {other:?} 不认识", e.id)),
            };
            Ok(Pairing {
                id: e.id,
                node_id,
                role,
                paired_at: e.paired_at,
            })
        })
        .collect()
}

fn parse_hex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MemBlob(Mutex<Option<Vec<u8>>>);
    impl platform::SecretBlobStore for MemBlob {
        fn read(&self) -> platform::Result<Option<Vec<u8>>> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn write(&self, bytes: &[u8]) -> platform::Result<()> {
            *self.0.lock().unwrap() = Some(bytes.to_vec());
            Ok(())
        }
        fn delete(&self) -> platform::Result<()> {
            *self.0.lock().unwrap() = None;
            Ok(())
        }
        fn location(&self) -> String {
            "mem".into()
        }
    }

    fn p(n: u8, id: &str, role: Role) -> Pairing {
        Pairing {
            id: id.into(),
            node_id: vec![n; 32],
            role,
            paired_at: 7,
        }
    }

    #[test]
    fn roundtrip_insert_replace_delete() {
        let v = SecretPairingVault::new(Box::<MemBlob>::default());
        assert!(
            v.load_all().unwrap().is_empty(),
            "没有条目 = 空白名单（首次）"
        );
        v.insert(&p(1, "a", Role::Member)).unwrap();
        v.insert(&p(2, "b", Role::Viewer)).unwrap();
        v.insert(&p(1, "a2", Role::Member)).unwrap();
        let mut all = v.load_all().unwrap();
        all.sort_by(|x, y| x.id.cmp(&y.id));
        assert_eq!(all, vec![p(1, "a2", Role::Member), p(2, "b", Role::Viewer)]);
        v.delete(&[1; 32]).unwrap();
        v.delete(&[9; 32]).unwrap();
        assert_eq!(v.load_all().unwrap(), vec![p(2, "b", Role::Viewer)]);
        v.delete_all().unwrap();
        assert!(v.load_all().unwrap().is_empty());
    }

    /// 正本内容读不懂：报错（daemon 拒绝启动），不当成空白名单。
    /// 反证：decode 失败时返回 `Ok(vec![])` ⇒ 这里红。
    #[test]
    fn garbage_is_an_error_not_an_empty_whitelist() {
        for bad in [
            &b"not json"[..],
            br#"{"version":2,"pairings":[]}"#,
            br#"{"version":1,"pairings":[{"id":"a","node_id":"00","role":"member","paired_at":1}]}"#,
            br#"{"version":1,"pairings":[{"id":"a","node_id":"0000000000000000000000000000000000000000000000000000000000000000","role":"owner","paired_at":1}]}"#,
        ] {
            let blob = MemBlob::default();
            *blob.0.lock().unwrap() = Some(bad.to_vec());
            let v = SecretPairingVault::new(Box::new(blob));
            assert!(v.load_all().is_err(), "{}", String::from_utf8_lossy(bad));
        }
    }
}
