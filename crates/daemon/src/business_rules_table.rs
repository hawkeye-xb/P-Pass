//! #1049 E2：`docs/desktop/business-rules.zh-CN.md` §12 常量表 ↔ 代码常量。
//!
//! 双向比对「归属 = daemon」的行：表里每一行都必须在下面的登记里且值、单位相等；
//! 登记里每个常量都必须在表里有一行。另核对整张表的「归属」只用已知的三个值
//! （desktop-shell / desktop-ui 的行由壳的 Rust 测试与 vitest 各自校验）。
//!
//! 改常量 ⇒ 改表；新增业务常量 ⇒ 登记 + 加行。`include_str!` 让文档变化也触发重编。

use std::collections::BTreeMap;

const DOC: &str = include_str!("../../../docs/desktop/business-rules.zh-CN.md");
const OWNER: &str = "daemon";
const KNOWN_OWNERS: [&str; 3] = ["daemon", "desktop-shell", "desktop-ui"];

#[derive(Debug, PartialEq)]
struct Row {
    owner: String,
    values: Vec<u128>,
    unit: String,
}

/// 取 `## 12` 节里的第一张表：`| 符号 | 归属 | 值 | 单位 | 规则 |`。
fn parse_table(doc: &str) -> BTreeMap<String, Row> {
    let start = doc.find("\n## 12 ").expect("文档缺少 `## 12 数字常量总表`");
    let section = &doc[start + 1..];
    let section = match section[3..].find("\n## ") {
        Some(end) => &section[..end + 3],
        None => section,
    };
    let mut rows = BTreeMap::new();
    let mut in_table = false;
    for line in section.lines() {
        let line = line.trim();
        if !line.starts_with('|') {
            if in_table {
                break;
            }
            continue;
        }
        let cells: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        if cells.first() == Some(&"符号") || cells.iter().all(|c| c.chars().all(|ch| ch == '-')) {
            in_table = true;
            continue;
        }
        assert!(cells.len() >= 4, "§12 表行列数不对：{line}");
        let symbol = cells[0].trim_matches('`').to_owned();
        let values = cells[2]
            .split(',')
            .map(|v| {
                v.trim()
                    .parse::<u128>()
                    .unwrap_or_else(|_| panic!("§12 `{symbol}` 的值不是整数：{}", cells[2]))
            })
            .collect();
        let row = Row {
            owner: cells[1].to_owned(),
            values,
            unit: cells[3].to_owned(),
        };
        assert!(
            rows.insert(symbol.clone(), row).is_none(),
            "§12 符号重复：{symbol}"
        );
    }
    assert!(!rows.is_empty(), "§12 没有解析出任何行");
    rows
}

fn ms(d: std::time::Duration) -> u128 {
    d.as_millis()
}

/// 代码侧登记：符号 → (值, 单位)。
fn registry() -> Vec<(&'static str, Vec<u128>, &'static str)> {
    use crate::{
        backup, diag_agg, diag_bundle, events, flow_delivery, log_guard, low_space, pairing,
        presence, query, watcher,
    };
    vec![
        (
            "daemon::pairing::TOKEN_TTL_MS",
            vec![pairing::TOKEN_TTL_MS as u128],
            "ms",
        ),
        (
            "daemon::pairing::PENDING_TTL_MS",
            vec![pairing::PENDING_TTL_MS as u128],
            "ms",
        ),
        (
            "daemon::pairing::MAX_DEVICE_NAME_CHARS",
            vec![pairing::MAX_DEVICE_NAME_CHARS as u128],
            "字符",
        ),
        (
            "daemon::presence::ONLINE_HEARTBEAT_MS",
            vec![presence::ONLINE_HEARTBEAT_MS as u128],
            "ms",
        ),
        (
            "daemon::presence::OFFLINE_SENTINEL_MS",
            vec![presence::OFFLINE_SENTINEL_MS as u128],
            "ms",
        ),
        (
            "daemon::presence::BACKUP_ATTENTION_MS",
            vec![presence::BACKUP_ATTENTION_MS as u128],
            "ms",
        ),
        (
            "daemon::flow_delivery::SPACE_RESERVE_BYTES",
            vec![flow_delivery::SPACE_RESERVE_BYTES as u128],
            "B",
        ),
        (
            "daemon::flow_delivery::FETCH_BYTE_STALL_LIMIT",
            vec![ms(flow_delivery::FETCH_BYTE_STALL_LIMIT)],
            "ms",
        ),
        (
            "daemon::flow_delivery::GRANT_RESUME_TTL_MS",
            vec![flow_delivery::GRANT_RESUME_TTL_MS as u128],
            "ms",
        ),
        (
            "daemon::backup::STAGING_ORPHAN_GRACE",
            vec![ms(backup::STAGING_ORPHAN_GRACE)],
            "ms",
        ),
        (
            "daemon::backup::SESSION_IDLE_TTL",
            vec![ms(backup::SESSION_IDLE_TTL)],
            "ms",
        ),
        (
            "core_index::MAX_REGION_BYTES",
            vec![core_index::MAX_REGION_BYTES as u128],
            "B",
        ),
        (
            "daemon::watcher::DEFAULT_DEBOUNCE",
            vec![ms(watcher::DEFAULT_DEBOUNCE)],
            "ms",
        ),
        (
            "daemon::watcher::DEFAULT_INGEST_CONCURRENCY",
            vec![watcher::DEFAULT_INGEST_CONCURRENCY as u128],
            "个",
        ),
        (
            "daemon::events::DEFAULT_THROTTLE_WINDOW",
            vec![ms(events::DEFAULT_THROTTLE_WINDOW)],
            "ms",
        ),
        (
            "daemon::PREGEN_WORKERS",
            vec![crate::PREGEN_WORKERS as u128],
            "个",
        ),
        (
            "media_codec::THUMB_SIZES",
            media_codec::THUMB_SIZES
                .iter()
                .map(|&v| v as u128)
                .collect(),
            "px",
        ),
        (
            "media_codec::JPEG_QUALITY",
            vec![media_codec::JPEG_QUALITY as u128],
            "个",
        ),
        (
            "daemon::query::THUMB_BUDGET",
            vec![ms(query::THUMB_BUDGET)],
            "ms",
        ),
        (
            "daemon::query::THUMB_RETRY_AFTER",
            vec![ms(query::THUMB_RETRY_AFTER)],
            "ms",
        ),
        (
            "daemon::query::ORIGINAL_CAP",
            vec![query::ORIGINAL_CAP as u128],
            "B",
        ),
        (
            "daemon::low_space::LOW_SPACE_THRESHOLD_BYTES",
            vec![low_space::LOW_SPACE_THRESHOLD_BYTES as u128],
            "B",
        ),
        (
            "daemon::low_space::LOW_SPACE_REARM_BYTES",
            vec![low_space::LOW_SPACE_REARM_BYTES as u128],
            "B",
        ),
        (
            "daemon::PATROL_INTERVAL",
            vec![ms(crate::PATROL_INTERVAL)],
            "ms",
        ),
        (
            "daemon::FLOW_BLOBS_GC_INTERVAL",
            vec![ms(crate::FLOW_BLOBS_GC_INTERVAL)],
            "ms",
        ),
        (
            "daemon::DIAG_PRUNE_INTERVAL",
            vec![ms(crate::DIAG_PRUNE_INTERVAL)],
            "ms",
        ),
        (
            "daemon::DAEMON_ALIVE_INTERVAL",
            vec![ms(crate::DAEMON_ALIVE_INTERVAL)],
            "ms",
        ),
        (
            "daemon::THUMB_BACKFILL_DELAY",
            vec![ms(crate::THUMB_BACKFILL_DELAY)],
            "ms",
        ),
        (
            "daemon::SHUTDOWN_DEADLINE",
            vec![ms(crate::SHUTDOWN_DEADLINE)],
            "ms",
        ),
        (
            "daemon::log_guard::SINK_CAP_BYTES",
            vec![log_guard::SINK_CAP_BYTES as u128],
            "B",
        ),
        (
            "daemon::log_guard::IDLE_GAP",
            vec![ms(log_guard::IDLE_GAP)],
            "ms",
        ),
        (
            "daemon::diag_agg::RING_DAYS_MS",
            vec![diag_agg::RING_DAYS_MS as u128],
            "ms",
        ),
        (
            "daemon::diag_bundle::DAEMON_LOG_TAIL",
            vec![diag_bundle::DAEMON_LOG_TAIL as u128],
            "B",
        ),
        (
            "daemon::diag_bundle::SMALL_LOG_TAIL",
            vec![diag_bundle::SMALL_LOG_TAIL as u128],
            "B",
        ),
        (
            "daemon::diag_bundle::IPC_TIMEOUT",
            vec![ms(diag_bundle::IPC_TIMEOUT)],
            "ms",
        ),
        ("proto::PROTO_VER", vec![proto::PROTO_VER as u128], "个"),
        (
            "proto::MIN_SUPPORTED_VER",
            vec![proto::MIN_SUPPORTED_VER as u128],
            "个",
        ),
    ]
}

/// 比对逻辑单独成函数，反证测试用一份篡改过的文档喂它。
fn mismatches(doc: &str) -> Vec<String> {
    let table = parse_table(doc);
    let mut out = Vec::new();
    for (symbol, row) in &table {
        if !KNOWN_OWNERS.contains(&row.owner.as_str()) {
            out.push(format!("`{symbol}` 的归属「{}」不是已知值", row.owner));
        }
    }
    let reg = registry();
    for (symbol, values, unit) in &reg {
        match table.get(*symbol) {
            None => out.push(format!("代码常量 `{symbol}` 在 §12 没有行")),
            Some(row) if row.owner != OWNER => {
                out.push(format!("`{symbol}` 归属应为 {OWNER}，表里是 {}", row.owner))
            }
            Some(row) if row.values != *values || row.unit != *unit => out.push(format!(
                "`{symbol}`：表里 {:?} {}，代码 {:?} {}",
                row.values, row.unit, values, unit
            )),
            Some(_) => {}
        }
    }
    for (symbol, row) in &table {
        if row.owner == OWNER && !reg.iter().any(|(s, _, _)| s == symbol) {
            out.push(format!("§12 行 `{symbol}` 没有对应的代码登记"));
        }
    }
    out
}

#[test]
fn section_12_matches_the_daemon_constants() {
    let bad = mismatches(DOC);
    assert!(
        bad.is_empty(),
        "§12 常量表与代码不一致：\n{}",
        bad.join("\n")
    );
}

/// 反证：改表里一个值、删一行、加一个未知归属，三种都必须被抓到。
#[test]
fn a_tampered_table_is_caught() {
    let changed = DOC.replacen(
        "| `daemon::pairing::TOKEN_TTL_MS` | daemon | 600000 |",
        "| `daemon::pairing::TOKEN_TTL_MS` | daemon | 600001 |",
        1,
    );
    assert_ne!(changed, DOC, "反证样本没改到");
    assert!(mismatches(&changed)
        .iter()
        .any(|m| m.contains("TOKEN_TTL_MS")));

    let dropped: String = DOC
        .lines()
        .filter(|l| !l.contains("`daemon::log_guard::IDLE_GAP`"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(mismatches(&dropped)
        .iter()
        .any(|m| m.contains("IDLE_GAP") && m.contains("没有行")));

    let stranger: String = DOC
        .lines()
        .flat_map(|l| {
            let extra = l
                .contains("`proto::PROTO_VER`")
                .then_some("| `x::Y` | elsewhere | 1 | ms | 反证 |");
            std::iter::once(l).chain(extra)
        })
        .collect::<Vec<_>>()
        .join("\n");
    assert!(mismatches(&stranger)
        .iter()
        .any(|m| m.contains("elsewhere")));
}
