//! #1993：Windows 重解析目标 UTF-8 字节安全比较与映射网络盘短路顺序契约测试。
//!
//! 跨平台在 `crates/platform/tests/` 下锁定两项生产不变量：
//! 1. `classify_reparse_target` 必须用字节切片比较 `starts_with_ignore_ascii_case(body, "Volume{")`，
//!    禁止对 `&str` 直接做 `body[..7]` 字节切片（第 7 字节落在中文 UTF-8 字符内部会 panic）；
//! 2. `windows_contains_remote_reparse_point` 在发起任何 `symlink_metadata` 之前必须先走
//!    盘符根 `drive_type_is_remote` 短路，且 `local_peer::is_valid_dir_fact_path_with`
//!    必须先检查 `!network_volume(path)` 再检查 `!reparse_point(path)`。
//!
//! 反证：退回 `body[..7]`、去掉 `drive_type_is_remote` 前置守卫或颠倒两个探针顺序，本文件测试立即变红。

fn fn_body<'a>(src: &'a str, sig: &str) -> &'a str {
    let start = src.find(sig).unwrap_or_else(|| panic!("找不到 {sig}"));
    let rest = &src[start..];
    let brace = rest.find('{').expect("函数没有函数体");
    let mut depth = 0usize;
    for (i, ch) in rest[brace..].char_indices() {
        match ch {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return &rest[brace..brace + i + 1];
                }
            }
            _ => {}
        }
    }
    panic!("{sig} 的函数体不闭合");
}

#[test]
fn classify_reparse_target_uses_byte_safe_ascii_prefix_for_volume_guid() {
    let src = include_str!("../src/lib.rs");
    let body = fn_body(src, "pub(crate) fn classify_reparse_target(");
    assert!(
        !body.contains("body[..7]"),
        "classify_reparse_target 不得对 &str 直接切片 body[..7]（非 UTF-8 字符边界会 panic）：{body}"
    );
    assert!(
        body.contains(r#"starts_with_ignore_ascii_case(body, "Volume{")"#),
        "classify_reparse_target 必须用按字节比较的 starts_with_ignore_ascii_case 匹配 Volume{{：{body}"
    );
}

#[test]
fn mapped_drive_short_circuits_before_reparse_stat_in_platform_and_local_peer() {
    let lib_src = include_str!("../src/lib.rs");
    let reparse_body = fn_body(lib_src, "fn windows_contains_remote_reparse_point(");
    let guard_pos = reparse_body
        .find("drive_type_is_remote(")
        .expect("windows_contains_remote_reparse_point 必须包含盘符根 drive_type_is_remote 守卫");
    let stat_pos = reparse_body
        .find("symlink_metadata(")
        .expect("windows_contains_remote_reparse_point 应包含 symlink_metadata");
    assert!(
        guard_pos < stat_pos,
        "盘符根 drive_type_is_remote 守卫必须排在任何 symlink_metadata 之前（避免映射盘先发起 SMB I/O）"
    );

    let peer_src = include_str!("../src/local_peer.rs");
    let valid_body = fn_body(peer_src, "fn is_valid_dir_fact_path_with(");
    let net_pos = valid_body
        .find("!network_volume(path)")
        .expect("is_valid_dir_fact_path_with 必须检查 !network_volume(path)");
    let rep_pos = valid_body
        .find("!reparse_point(path)")
        .expect("is_valid_dir_fact_path_with 必须检查 !reparse_point(path)");
    assert!(
        net_pos < rep_pos,
        "is_valid_dir_fact_path_with 必须先检查 !network_volume(path) 再检查 !reparse_point(path)"
    );
}
