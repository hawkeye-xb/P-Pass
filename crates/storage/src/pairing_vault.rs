//! #1115：配对记录（= 设备白名单）的正本放在库外。
//!
//! 库文件同一用户可写——直接往 `pairing` 表插一行，效果等于批准一台新设备。所以授权
//! 依据不能是库：macOS 上正本在钥匙串里（只有带访问组授权的签名 daemon 读写得了），
//! 库里的 `pairing` 表退化为**镜像**，只为外键与级联删除存在（备份水位、交付租约挂在
//! 它上面）。授权判定读内存副本，内存副本只从正本加载、只随正本写入而变。
//!
//! ## 写入顺序（崩溃收敛）
//!
//! 判据：任何一步失败或进程在任何两步之间崩溃，下次启动都能收敛，且**不会出现
//! 「正本里没有、镜像里有」时仍被授权**——授权只看内存副本，内存副本只从正本加载。
//!
//! - **配对落定**：① 库事务（档案 + 镜像行）提交 → ② 写正本 → ③ 更新内存副本。
//!   - ②失败：删掉①刚插的镜像行（尽力），返回错误；内存副本没动，没有授权。
//!   - 崩在①②之间：镜像有、正本没有 ⇒ 启动对齐删掉镜像行（级联清掉挂在上面的状态），
//!     不授权；手机没收到 accepted，重新扫码即可。
//!   - 崩在②③之间：正本有 ⇒ 启动时从正本加载，授权（业主确实批准过）。
//! - **删除 / 全部删除**：① 删正本 → ② 更新内存副本（立即失去授权）→ ③ 库事务
//!   （删镜像行、档案记离开原因）。
//!   - ①失败：什么都不改，返回错误（授权照旧，调用方报失败）。
//!   - ③失败或崩在②③之间：镜像还在、正本没有 ⇒ 当下已不授权；启动对齐删掉镜像行。
//!
//! ## 启动对齐（正本 → 镜像，单向）
//!
//! 读正本失败 ⇒ 打开失败，daemon 拒绝启动（与 #1109 同口径），**不回退到镜像**。
//! - 镜像里有、正本里没有（或 id 不同）的行：删除（级联清掉传输状态）。
//! - 正本里有、镜像里没有的：补回镜像行；没有档案就建一个占位档案。
//! - 内存副本 = 正本。

use crate::Pairing;

/// 配对记录的正本存放处。实现必须是「整份」语义：每个方法返回时，正本已经是调用
/// 之后的样子，或者报错且正本没变。
pub trait PairingVault: Send + Sync + 'static {
    /// 全部配对记录。读不出来（钥匙串锁定、缺授权、内容坏了）一律 `Err`——绝不当成空。
    fn load_all(&self) -> Result<Vec<Pairing>, String>;
    /// 写入这台设备的配对记录（按 NodeId 替换旧的）。
    fn insert(&self, pairing: &Pairing) -> Result<(), String>;
    /// 删掉这台设备的配对记录；本来就没有不算错。
    fn delete(&self, node_id: &[u8]) -> Result<(), String>;
    /// 删掉全部配对记录。
    fn delete_all(&self) -> Result<(), String>;
    /// 给人看的位置（日志、启动失败说明），不含内容。
    fn location(&self) -> String;
}

/// 启动对齐的结果（只为日志与测试；对齐本身已经做完）。
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct VaultAlignment {
    /// 镜像里有、正本里没有而被删掉的行（node_id, 镜像里的 pairing id）。
    pub removed_from_mirror: Vec<(Vec<u8>, String)>,
    /// 正本里有、镜像里没有而补回的行。
    pub restored_to_mirror: Vec<(Vec<u8>, String)>,
}

impl VaultAlignment {
    pub fn is_noop(&self) -> bool {
        self.removed_from_mirror.is_empty() && self.restored_to_mirror.is_empty()
    }
}

/// 内存里的正本：测试用（崩溃收敛、对齐的单测）。可以注入失败。
#[derive(Default)]
pub struct MemoryVault {
    inner: std::sync::Mutex<MemoryVaultState>,
}

#[derive(Default)]
struct MemoryVaultState {
    pairings: Vec<Pairing>,
    fail_next: Option<&'static str>,
}

impl MemoryVault {
    pub fn with(pairings: Vec<Pairing>) -> Self {
        Self {
            inner: std::sync::Mutex::new(MemoryVaultState {
                pairings,
                fail_next: None,
            }),
        }
    }

    /// 下一次调用名为 `op`（"load_all" / "insert" / "delete" / "delete_all"）的方法失败。
    pub fn fail_next(&self, op: &'static str) {
        self.state().fail_next = Some(op);
    }

    pub fn snapshot(&self) -> Vec<Pairing> {
        self.state().pairings.clone()
    }

    fn state(&self) -> std::sync::MutexGuard<'_, MemoryVaultState> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn check(&self, op: &'static str) -> Result<(), String> {
        let mut s = self.state();
        if s.fail_next == Some(op) {
            s.fail_next = None;
            return Err(format!("注入的 {op} 失败"));
        }
        Ok(())
    }
}

impl PairingVault for MemoryVault {
    fn load_all(&self) -> Result<Vec<Pairing>, String> {
        self.check("load_all")?;
        Ok(self.snapshot())
    }

    fn insert(&self, pairing: &Pairing) -> Result<(), String> {
        self.check("insert")?;
        let mut s = self.state();
        s.pairings.retain(|p| p.node_id != pairing.node_id);
        s.pairings.push(pairing.clone());
        Ok(())
    }

    fn delete(&self, node_id: &[u8]) -> Result<(), String> {
        self.check("delete")?;
        self.state().pairings.retain(|p| p.node_id != node_id);
        Ok(())
    }

    fn delete_all(&self) -> Result<(), String> {
        self.check("delete_all")?;
        self.state().pairings.clear();
        Ok(())
    }

    fn location(&self) -> String {
        "内存（测试）".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Db, DepartedBy, Role, StorageError};
    use std::sync::Arc;

    fn pairing(n: u8, id: &str) -> Pairing {
        Pairing {
            id: id.into(),
            node_id: vec![n; 32],
            role: Role::Member,
            paired_at: 1_000 + i64::from(n),
        }
    }

    async fn mirror_ids(db: &Db) -> Vec<String> {
        let mut v: Vec<String> = db
            .list_pairings()
            .await
            .unwrap()
            .into_iter()
            .map(|p| p.id)
            .collect();
        v.sort();
        v
    }

    async fn open(dir: &std::path::Path, vault: &Arc<MemoryVault>) -> (Db, VaultAlignment) {
        Db::open_with_vault(
            &dir.join("index.sqlite"),
            Arc::clone(vault) as Arc<dyn PairingVault>,
        )
        .await
        .unwrap()
    }

    /// 配对落定：正本、镜像、内存副本三处都有。
    #[tokio::test]
    async fn accept_writes_vault_mirror_and_index() {
        let vault = Arc::new(MemoryVault::default());
        let (db, _) = Db::open_in_memory_with_vault(vault.clone()).await.unwrap();
        let p = pairing(1, "p1");
        db.accept_pairing(&p.node_id, "phone", &p).await.unwrap();
        assert_eq!(vault.snapshot(), vec![p.clone()]);
        assert_eq!(mirror_ids(&db).await, vec!["p1"]);
        assert_eq!(db.active_pairing(&p.node_id), Some(p));
    }

    /// 正本写不进去：报错、撤掉镜像行、不授权。
    /// 反证：accept_pairing 忘了在正本失败时返回错误 / 先改内存副本 ⇒ active_pairing 有值，红。
    #[tokio::test]
    async fn vault_insert_failure_grants_nothing() {
        let vault = Arc::new(MemoryVault::default());
        let (db, _) = Db::open_in_memory_with_vault(vault.clone()).await.unwrap();
        vault.fail_next("insert");
        let p = pairing(1, "p1");
        let err = db
            .accept_pairing(&p.node_id, "phone", &p)
            .await
            .unwrap_err();
        assert!(matches!(err, StorageError::Vault { .. }), "{err}");
        assert_eq!(db.active_pairing(&p.node_id), None);
        assert!(mirror_ids(&db).await.is_empty(), "镜像行要撤掉");
        assert!(vault.snapshot().is_empty());
    }

    /// 崩在「镜像已落库、正本还没写」之间：重启后镜像行被删，挂在上面的水位级联清掉，不授权。
    #[tokio::test]
    async fn crash_between_mirror_and_vault_converges_to_unpaired() {
        let dir = tempfile::tempdir().unwrap();
        let p = pairing(1, "p1");
        // 用没有正本的打开方式造出「只有镜像行」的磁盘状态（= 崩溃现场）。
        {
            let db = Db::open(&dir.path().join("index.sqlite")).await.unwrap();
            db.accept_pairing(&p.node_id, "phone", &p).await.unwrap();
            db.set_watermark(&p.id, 42, 5).await.unwrap();
        }
        let vault = Arc::new(MemoryVault::default());
        let (db, aligned) = open(dir.path(), &vault).await;
        assert_eq!(db.active_pairing(&p.node_id), None);
        assert_eq!(aligned.removed_from_mirror.len(), 1);
        assert_eq!(db.get_watermark(&p.id).await.unwrap(), None, "级联清掉");
    }

    /// 崩在「正本已写、内存副本没更新」之间 / 镜像行被删：正本说了算，重启后补回镜像并授权。
    #[tokio::test]
    async fn vault_entry_without_mirror_row_is_restored_and_authorized() {
        let dir = tempfile::tempdir().unwrap();
        let p = pairing(2, "p2");
        let vault = Arc::new(MemoryVault::with(vec![p.clone()]));
        let (db, aligned) = open(dir.path(), &vault).await;
        assert_eq!(db.active_pairing(&p.node_id), Some(p.clone()));
        assert_eq!(
            aligned.restored_to_mirror,
            vec![(p.node_id.clone(), "p2".to_string())]
        );
        assert_eq!(mirror_ids(&db).await, vec!["p2"]);
        // 水位能挂上去（外键成立）。
        db.set_watermark(&p.id, 1, 1).await.unwrap();
    }

    /// 镜像里的 id 与正本不同（被改过 / 旧配对残留）：以正本为准替换。
    #[tokio::test]
    async fn mirror_row_with_another_id_is_replaced_by_the_vault_one() {
        let dir = tempfile::tempdir().unwrap();
        {
            let db = Db::open(&dir.path().join("index.sqlite")).await.unwrap();
            let old = pairing(3, "old");
            db.accept_pairing(&old.node_id, "phone", &old)
                .await
                .unwrap();
        }
        let current = pairing(3, "new");
        let vault = Arc::new(MemoryVault::with(vec![current.clone()]));
        let (db, aligned) = open(dir.path(), &vault).await;
        assert_eq!(db.active_pairing(&current.node_id), Some(current));
        assert_eq!(aligned.removed_from_mirror.len(), 1);
        assert_eq!(aligned.restored_to_mirror.len(), 1);
        assert_eq!(mirror_ids(&db).await, vec!["new"]);
    }

    /// 删除：先删正本、立即不授权；正本删不掉就什么都不改（授权照旧，报错）。
    #[tokio::test]
    async fn remove_goes_through_the_vault_first() {
        let vault = Arc::new(MemoryVault::default());
        let (db, _) = Db::open_in_memory_with_vault(vault.clone()).await.unwrap();
        let p = pairing(1, "p1");
        db.accept_pairing(&p.node_id, "phone", &p).await.unwrap();

        vault.fail_next("delete");
        assert!(db
            .remove_pairing(&p.node_id, None, DepartedBy::Owner, 9)
            .await
            .is_err());
        assert_eq!(
            db.active_pairing(&p.node_id),
            Some(p.clone()),
            "正本没删掉就不能当成删了"
        );
        assert_eq!(mirror_ids(&db).await, vec!["p1"]);

        // expect_id 不符：不动（#565 语义保留）。
        assert_eq!(
            db.remove_pairing(&p.node_id, Some("other"), DepartedBy::Device, 9)
                .await
                .unwrap(),
            None
        );
        assert_eq!(db.active_pairing(&p.node_id), Some(p.clone()));

        let removed = db
            .remove_pairing(&p.node_id, Some("p1"), DepartedBy::Owner, 9)
            .await
            .unwrap();
        assert_eq!(removed, Some(p.clone()));
        assert!(vault.snapshot().is_empty());
        assert_eq!(db.active_pairing(&p.node_id), None);
        assert!(mirror_ids(&db).await.is_empty());
        let row = db.get_device(&p.node_id).await.unwrap().unwrap();
        assert_eq!(row.profile.departed_by, Some(DepartedBy::Owner));
    }

    #[tokio::test]
    async fn remove_all_clears_vault_index_and_mirror() {
        let vault = Arc::new(MemoryVault::default());
        let (db, _) = Db::open_in_memory_with_vault(vault.clone()).await.unwrap();
        for (n, id) in [(1, "a"), (2, "b")] {
            let p = pairing(n, id);
            db.accept_pairing(&p.node_id, "phone", &p).await.unwrap();
        }
        let mut removed = db
            .remove_all_pairings(DepartedBy::Identity, 7)
            .await
            .unwrap();
        removed.sort_by(|a, b| a.id.cmp(&b.id));
        assert_eq!(
            removed.iter().map(|p| p.id.as_str()).collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert!(vault.snapshot().is_empty());
        assert_eq!(db.active_pairing(&[1u8; 32]), None);
        assert!(mirror_ids(&db).await.is_empty());
    }

    /// 读正本失败：打不开（调用方拒绝启动），绝不回退到镜像。
    #[tokio::test]
    async fn unreadable_vault_fails_the_open() {
        let vault = Arc::new(MemoryVault::default());
        vault.fail_next("load_all");
        let err = Db::open_in_memory_with_vault(vault)
            .await
            .err()
            .expect("必须失败");
        assert!(matches!(err, StorageError::Vault { .. }), "{err}");
    }
}
