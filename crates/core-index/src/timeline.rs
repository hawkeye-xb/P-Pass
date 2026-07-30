//! Timeline — domain façade over storage's keyset paging, so proto
//! handlers depend on core-index instead of reaching into storage.

use storage::{Db, TimelinePage};

use crate::Result;

/// Newest-first page of the family timeline. `cursor: None` = first page;
/// feed `next_cursor` back in until it is `None`.
pub async fn timeline_page(db: &Db, cursor: Option<&str>, limit: u32) -> Result<TimelinePage> {
    Ok(db.timeline_page(cursor, limit).await?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use storage::Asset;

    #[tokio::test]
    async fn facade_pages_like_storage() {
        let db = Db::open_in_memory().await.unwrap();
        for n in 0..5u8 {
            db.insert_asset(&Asset {
                hash: {
                    let mut h = vec![0u8; 32];
                    h[0] = n;
                    h
                },
                rel_path: format!("originals/d/2026/07/{n}.jpg"),
                media_type: "image/jpeg".into(),
                bytes: 1,
                taken_at: Some(1_700_000_000_000 + i64::from(n)),
                width: None,
                height: None,
                src_device: vec![1u8; 32],
                added_at: 0,
                thumb_state: 0,
            })
            .await
            .unwrap();
        }
        let p1 = timeline_page(&db, None, 3).await.unwrap();
        assert_eq!(p1.assets.len(), 3);
        let p2 = timeline_page(&db, p1.next_cursor.as_deref(), 3)
            .await
            .unwrap();
        assert_eq!(p2.assets.len(), 2);
        assert!(p2.next_cursor.is_none());
    }
}
