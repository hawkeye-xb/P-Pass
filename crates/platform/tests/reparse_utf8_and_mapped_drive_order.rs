//! #1993：Windows 重解析目标 UTF-8 字节安全比较与三阶零外连检查顺序契约测试。
//!
//! 跨平台在 `crates/platform/tests/` 下锁定生产不变量：
//! 1. `classify_reparse_target` 必须用字节切片比较 `starts_with_ignore_ascii_case(body, "Volume{")`，
//!    禁止对 `&str` 直接做 `body[..7]` 字节切片（第 7 字节落在中文 UTF-8 字符内部会 panic）；
//! 2. `is_mapped_network_drive` 内部严禁调用 `symlink_metadata` / `canonicalize` / `GetVolumePathNameW`
//!    等任何会访问文件系统或解析中间链接的调用（Windows 仅对盘符根调 `GetDriveTypeW`）；
//! 3. `windows_contains_remote_reparse_point` 在发起任何 `symlink_metadata` 之前必须先走
//!    `is_mapped_network_drive` 短路；
//! 4. `local_peer::is_valid_dir_fact_path_with` 与 `daemon::library_location::check_library_path_with`
//!    必须严格按「零 I/O 映射盘符根 → 不跟随扫描远端重解析点 → 完整网络卷」三阶顺序执行，既保证映射盘
//!    `Z:\...` 零外连且报 `ui.err_relocate_network_volume`，又保证 `C:\entry\sub`（中间链接指向远端）
//!    先由不跟随扫描拦截而不被 `is_network_volume_or_ancestor` 穿过中间链接触发 SMB 外连。
//!
//! 反证：退回 `body[..7]`、在 `is_mapped_network_drive` 里引入 stat、去掉前置守卫或颠倒三阶顺序，本测试立即变红。

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
fn mapped_drive_probe_is_zero_io_and_three_stage_order_is_preserved() {
    let lib_src = include_str!("../src/lib.rs");
    let mapped_body = fn_body(lib_src, "pub fn is_mapped_network_drive(");
    for forbidden in [
        "symlink_metadata",
        "metadata(",
        "canonicalize",
        "windows_volume_root",
        "GetVolumePathNameW",
    ] {
        assert!(
            !mapped_body.contains(forbidden),
            "is_mapped_network_drive 必须零文件系统访问，禁止包含 {forbidden}：{mapped_body}"
        );
    }

    let reparse_body = fn_body(lib_src, "fn windows_contains_remote_reparse_point(");
    let guard_pos = reparse_body
        .find("is_mapped_network_drive(")
        .expect("windows_contains_remote_reparse_point 必须包含 is_mapped_network_drive 守卫");
    let stat_pos = reparse_body
        .find("symlink_metadata(")
        .expect("windows_contains_remote_reparse_point 应包含 symlink_metadata");
    assert!(
        guard_pos < stat_pos,
        "is_mapped_network_drive 守卫必须排在任何 symlink_metadata 之前（避免映射盘先发起 SMB I/O）"
    );

    let peer_src = include_str!("../src/local_peer.rs");
    let valid_body = fn_body(peer_src, "fn is_valid_dir_fact_path_with(");
    let mapped_pos = valid_body
        .find("!mapped_drive(path)")
        .expect("is_valid_dir_fact_path_with 必须检查 !mapped_drive(path)");
    let rep_pos = valid_body
        .find("!reparse_point(path)")
        .expect("is_valid_dir_fact_path_with 必须检查 !reparse_point(path)");
    let net_pos = valid_body
        .find("!network_volume(path)")
        .expect("is_valid_dir_fact_path_with 必须检查 !network_volume(path)");
    assert!(
        mapped_pos < rep_pos && rep_pos < net_pos,
        "is_valid_dir_fact_path_with 必须严格按 !mapped_drive -> !reparse_point -> !network_volume 三阶顺序执行"
    );

    let loc_src = include_str!("../../daemon/src/library_location.rs");
    let check_body = fn_body(loc_src, "fn check_library_path_with(");
    let loc_mapped = check_body
        .find("if mapped_drive(target)")
        .expect("check_library_path_with 必须先检查 if mapped_drive(target)");
    let loc_rep = check_body
        .find("if remote_reparse(target)")
        .expect("check_library_path_with 必须检查 if remote_reparse(target)");
    let loc_net = check_body
        .find("if network_volume(target)")
        .expect("check_library_path_with 必须检查 if network_volume(target)");
    assert!(
        loc_mapped < loc_rep && loc_rep < loc_net,
        "check_library_path_with 必须严格按 mapped_drive -> remote_reparse -> network_volume 三阶顺序执行"
    );
}
