//! 版本关系（#1044 B13）——daemon 与桌面壳共用的**唯一**实现。
//!
//! 过去有 5 份：daemon `ipc.rs` 与壳 `lib.rs` 各抄一份 `version_cmp`，前端又有
//! `sameRelease`/`isOlder`，而且语义互相冲突（JS 忽略 `-test.N`，Rust 不忽略）。
//! 拍板采用 Rust 语义：
//!
//! - 数字段逐段比（缺的段按 0）：`0.10.0` > `0.9.12`，日历批次号 `2026.10.5`
//!   与 semver `0.9.7` 同样按数字比；前缀 `v` 等非数字字符不参与；
//! - 核心相同时，**预发布版小于正式版**：`0.9.12-test.17` < `0.9.12`；
//! - 两个预发布按其数字段比：`test.10` > `test.9`——test 通道上 test.1 与
//!   test.2 是不同的二进制，必须分得出新旧。

use std::cmp::Ordering;

/// 比较两个版本串（语义见模块注释）。
pub fn version_cmp(a: &str, b: &str) -> Ordering {
    let (core_a, pre_a) = parse(a);
    let (core_b, pre_b) = parse(b);
    match cmp_segments(&core_a, &core_b) {
        Ordering::Equal => {}
        other => return other,
    }
    match (pre_a, pre_b) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(x), Some(y)) => cmp_segments(&x, &y),
    }
}

/// 运行中的桌面壳相对后台服务（内核）的版本关系。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellRelation {
    /// 同一个版本。
    Same,
    /// 壳比内核旧（更新装了新内核、壳还没重启）。
    ShellOlder,
    /// 壳比内核新（壳已更新、内核还在跑旧版本——该换内核）。
    ShellNewer,
}

impl ShellRelation {
    pub fn of(shell: &str, daemon: &str) -> Self {
        match version_cmp(shell, daemon) {
            Ordering::Equal => ShellRelation::Same,
            Ordering::Less => ShellRelation::ShellOlder,
            Ordering::Greater => ShellRelation::ShellNewer,
        }
    }

    /// 线上值（`status.shell_relation`）。
    pub fn as_str(self) -> &'static str {
        match self {
            ShellRelation::Same => "same",
            ShellRelation::ShellOlder => "shell_older",
            ShellRelation::ShellNewer => "shell_newer",
        }
    }
}

fn parse(s: &str) -> (Vec<u64>, Option<Vec<u64>>) {
    match s.split_once('-') {
        Some((core, pre)) => (nums(core), Some(nums(pre))),
        None => (nums(s), None),
    }
}

fn nums(seg: &str) -> Vec<u64> {
    seg.split(|c: char| !c.is_ascii_digit())
        .filter(|p| !p.is_empty())
        .map(|p| p.parse().unwrap_or(0))
        .collect()
}

fn cmp_segments(a: &[u64], b: &[u64]) -> Ordering {
    for i in 0..a.len().max(b.len()) {
        let (x, y) = (
            a.get(i).copied().unwrap_or(0),
            b.get(i).copied().unwrap_or(0),
        );
        if x != y {
            return x.cmp(&y);
        }
    }
    Ordering::Equal
}

#[cfg(test)]
mod tests {
    use super::*;
    use Ordering::*;

    #[test]
    fn numeric_segments() {
        assert_eq!(version_cmp("0.1.0", "0.1.0"), Equal);
        assert_eq!(version_cmp("0.2.0", "0.1.0"), Greater);
        assert_eq!(version_cmp("1.0.0", "0.9.9"), Greater);
        assert_eq!(version_cmp("0.10.0", "0.9.0"), Greater);
        assert_eq!(version_cmp("v0.9.7", "0.9.7"), Equal, "v 前缀不参与");
        assert_eq!(version_cmp("0.9", "0.9.0"), Equal, "缺的段按 0");
        assert_eq!(version_cmp("", "0.0.0"), Equal, "垃圾输入退化为 0");
        assert_eq!(version_cmp("alpha", "0.1.0"), Less);
    }

    #[test]
    fn prerelease_sorts_below_its_release_and_by_number_among_itself() {
        assert_eq!(version_cmp("0.9.12-test.17", "0.9.12"), Less);
        assert_eq!(version_cmp("0.1.0", "0.1.0-test.3"), Greater);
        assert_eq!(version_cmp("0.2.0-test.7", "0.1.0"), Greater);
        assert_eq!(version_cmp("0.2.0-test.8", "0.2.0-test.7"), Greater);
        assert_eq!(version_cmp("0.10.0-test.10", "0.10.0-test.9"), Greater);
    }

    /// 现行两种版本串形状：各端 app 版本是 semver（`0.9.7`，test 通道
    /// `0.10.0-test.3`），发布 tag 是日历批次号（`2026.10.5`）。按数字段
    /// 比两种都成立。
    #[test]
    fn semver_and_calendar_shapes() {
        assert_eq!(version_cmp("0.9.7", "0.10.0-test.3"), Less);
        assert_eq!(version_cmp("2026.10.5", "0.9.12"), Greater);
        assert_eq!(version_cmp("2026.10.5", "2026.10.4"), Greater);
        assert_eq!(version_cmp("2026.10.10", "2026.10.9"), Greater);
    }

    #[test]
    fn shell_relation_wire_values() {
        assert_eq!(ShellRelation::of("0.9.7", "0.9.7").as_str(), "same");
        assert_eq!(ShellRelation::of("0.9.7", "0.9.8").as_str(), "shell_older");
        assert_eq!(ShellRelation::of("0.9.8", "0.9.7").as_str(), "shell_newer");
        // JS 旧语义会把这两个当成同一版；Rust 语义下 test 包与正式包不同。
        assert_eq!(
            ShellRelation::of("0.9.12", "0.9.12-test.17").as_str(),
            "shell_newer"
        );
    }
}
