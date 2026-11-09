//! #1582：Windows 服务形态点「启动」必须真的走 `StartServiceW` 并等到 RUNNING。
//!
//! 服务分支的私有 helper 在 Windows-only 模块里，集成测试构造不了 SCM；这里用同仓
//! 源文件钉住生产调用链：`install_autostart` 的服务分支必须调用
//! `start_installed_service(start_and_wait)`，对账路径 `rewrite_autostart` 不能拉起服务。
//! 把调用删回 `Ok(())`，这些断言会红。

/// 取出 `sig` 开头的函数体（配平大括号）。只用于本文件的源码契约测试。
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
fn install_autostart_service_branch_starts_the_service() {
    let src = include_str!("../src/windows.rs");
    let body = fn_body(src, "fn install_autostart");
    assert!(
        body.contains("start_installed_service("),
        "服务分支必须调用 start_installed_service：{body}"
    );
    assert!(
        body.contains("windows_service::start_and_wait("),
        "服务分支必须调用 start_and_wait：{body}"
    );
}

#[test]
fn rewrite_autostart_does_not_start_the_service() {
    let src = include_str!("../src/windows.rs");
    let body = fn_body(src, "fn rewrite_autostart");
    assert!(
        body.contains("is_installed"),
        "服务形态要用 is_installed 判登记：{body}"
    );
    assert!(
        !body.contains("start_and_wait"),
        "对账只改登记，不能拉起服务：{body}"
    );
}

#[test]
fn start_and_wait_waits_for_running() {
    let src = include_str!("../src/windows_service.rs");
    let body = fn_body(src, "fn start_and_wait");
    assert!(body.contains("start(name)?"), "必须先 StartServiceW：{body}");
    assert!(
        body.contains("ServiceState::Running"),
        "必须等到 RUNNING：{body}"
    );
    assert!(
        body.contains("Duration::from_secs(10)"),
        "超时上限 10 秒：{body}"
    );
}

#[test]
fn start_installed_service_really_calls_start() {
    let src = include_str!("../src/windows.rs");
    let body = fn_body(src, "fn start_installed_service");
    assert!(
        body.contains("start()?"),
        "已安装分支必须真的调用 start：{body}"
    );
}
