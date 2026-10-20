//! #1049 E2：`docs/desktop/business-rules.zh-CN.md` §12 常量表里「归属 = desktop-shell」
//! 的行 ↔ 壳的代码常量，双向比对（daemon 与前端的行由各自的测试校验）。

use std::collections::BTreeMap;
use std::time::Duration;

const DOC: &str = include_str!("../../../../docs/desktop/business-rules.zh-CN.md");
const OWNER: &str = "desktop-shell";

/// `## 12` 节第一张表：符号 → (归属, 值, 单位)。
fn parse_table(doc: &str) -> BTreeMap<String, (String, u128, String)> {
    let start = doc.find("\n## 12 ").expect("文档缺少 `## 12 数字常量总表`") + 1;
    let section = &doc[start..];
    let section = section[3..]
        .find("\n## ")
        .map_or(section, |e| &section[..e + 3]);
    let mut rows = BTreeMap::new();
    let mut in_table = false;
    for line in section.lines().map(str::trim) {
        if !line.starts_with('|') {
            if in_table {
                break;
            }
            continue;
        }
        let cells: Vec<&str> = line.trim_matches('|').split('|').map(str::trim).collect();
        if cells[0] == "符号" || cells.iter().all(|c| c.chars().all(|ch| ch == '-')) {
            in_table = true;
            continue;
        }
        if cells[1] != OWNER {
            continue;
        }
        let symbol = cells[0].trim_matches('`').to_owned();
        let value = cells[2]
            .parse::<u128>()
            .unwrap_or_else(|_| panic!("§12 `{symbol}` 的值不是整数：{}", cells[2]));
        rows.insert(symbol, (cells[1].to_owned(), value, cells[3].to_owned()));
    }
    rows
}

fn registry() -> Vec<(&'static str, u128, &'static str)> {
    let ms = |d: Duration| d.as_millis();
    vec![
        ("desktop::RESTART_GRACE", ms(crate::RESTART_GRACE), "ms"),
        (
            "desktop::KERNEL_CONVERGE_POLL",
            ms(crate::KERNEL_CONVERGE_POLL),
            "ms",
        ),
        (
            "desktop::ipc::IPC_READ_TIMEOUT",
            ms(crate::ipc::IPC_READ_TIMEOUT),
            "ms",
        ),
        (
            "desktop::daemon_cli::PROBE_TIMEOUT",
            ms(crate::daemon_cli::PROBE_TIMEOUT),
            "ms",
        ),
        (
            "desktop::daemon_cli::CONFIG_TIMEOUT",
            ms(crate::daemon_cli::CONFIG_TIMEOUT),
            "ms",
        ),
        (
            "desktop::daemon_cli::DIAG_TIMEOUT",
            ms(crate::daemon_cli::DIAG_TIMEOUT),
            "ms",
        ),
        (
            "desktop::service_state::MAX_LOG_BYTES",
            crate::service_state::MAX_LOG_BYTES as u128,
            "B",
        ),
        (
            "desktop::service_state::FAILURE_LOG_INTERVAL_MS",
            crate::service_state::FAILURE_LOG_INTERVAL_MS as u128,
            "ms",
        ),
    ]
}

fn mismatches(doc: &str) -> Vec<String> {
    let table = parse_table(doc);
    let reg = registry();
    let mut out = Vec::new();
    for (symbol, value, unit) in &reg {
        match table.get(*symbol) {
            None => out.push(format!("代码常量 `{symbol}` 在 §12 没有 {OWNER} 行")),
            Some((_, v, u)) if v != value || u != unit => {
                out.push(format!("`{symbol}`：表里 {v} {u}，代码 {value} {unit}"))
            }
            Some(_) => {}
        }
    }
    for symbol in table.keys() {
        if !reg.iter().any(|(s, _, _)| s == symbol) {
            out.push(format!("§12 行 `{symbol}` 没有对应的代码登记"));
        }
    }
    out
}

#[test]
fn section_12_matches_the_shell_constants() {
    let bad = mismatches(DOC);
    assert!(
        bad.is_empty(),
        "§12 常量表与壳代码不一致：\n{}",
        bad.join("\n")
    );
}

/// 反证：改一个值、删一行，都必须被抓到。
#[test]
fn a_tampered_table_is_caught() {
    let changed = DOC.replacen(
        "| `desktop::RESTART_GRACE` | desktop-shell | 90000 |",
        "| `desktop::RESTART_GRACE` | desktop-shell | 12000 |",
        1,
    );
    assert_ne!(changed, DOC, "反证样本没改到");
    assert!(mismatches(&changed)
        .iter()
        .any(|m| m.contains("RESTART_GRACE")));

    let dropped: String = DOC
        .lines()
        .filter(|l| !l.contains("`desktop::daemon_cli::DIAG_TIMEOUT`"))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(mismatches(&dropped)
        .iter()
        .any(|m| m.contains("DIAG_TIMEOUT")));
}
