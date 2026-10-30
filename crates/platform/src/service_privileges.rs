//! 常驻服务的令牌特权：安装器声明的白名单与 daemon 启动时的核对口径。
//!
//! 安装器用 `sc privs` 声明服务需要的特权（`SERVICE_CONFIG_REQUIRED_PRIVILEGES_INFO`），
//! 系统据此从服务令牌里去掉其余特权。daemon 启动时再读一遍自己的令牌：出现
//! [`FORBIDDEN_SERVICE_PRIVILEGES`] 里任一项就拒绝启动（和 ProgramData 目录核对同一模式）；
//! 其余不在白名单里的特权写进启动日志，不静默。
//!
//! 判定是纯函数，放在平台无关的模块里，各平台都能跑单测；读令牌在 `windows_token.rs`。

/// 服务需要的特权。安装器 `installer-hooks.nsh` 的 `sc privs` 行必须与它**完全一致**
/// （壳的配置锁定测试比对两边）。
pub const SERVICE_PRIVILEGE_ALLOWLIST: &[&str] = &["SeChangeNotifyPrivilege"];

/// 出现任一项，服务就拒绝启动。
pub const FORBIDDEN_SERVICE_PRIVILEGES: &[&str] = &[
    "SeImpersonatePrivilege",
    "SeAssignPrimaryTokenPrivilege",
    "SeDebugPrivilege",
    "SeTcbPrivilege",
    "SeBackupPrivilege",
    "SeRestorePrivilege",
    "SeTakeOwnershipPrivilege",
    "SeLoadDriverPrivilege",
];

/// 令牌特权核对的结果。按特权**存在**判，不看是否启用：存在但未启用的特权，进程自己就能启用。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ServicePrivilegeVerdict {
    /// 禁止项（非空 = 拒绝启动）。
    pub forbidden: Vec<String>,
    /// 不在白名单、也不在禁止项里的特权（写日志，不阻断）。
    pub unexpected: Vec<String>,
}

impl ServicePrivilegeVerdict {
    pub fn is_allowed(&self) -> bool {
        self.forbidden.is_empty()
    }
}

/// 按特权名判定（名字大小写不敏感，与系统 `LookupPrivilegeNameW` 的写法无关）。
pub fn judge_service_privileges<S: AsRef<str>>(present: &[S]) -> ServicePrivilegeVerdict {
    let mut verdict = ServicePrivilegeVerdict::default();
    for name in present {
        let name = name.as_ref();
        let is = |list: &[&str]| list.iter().any(|p| p.eq_ignore_ascii_case(name));
        if is(FORBIDDEN_SERVICE_PRIVILEGES) {
            verdict.forbidden.push(name.to_string());
        } else if !is(SERVICE_PRIVILEGE_ALLOWLIST) {
            verdict.unexpected.push(name.to_string());
        }
    }
    verdict
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_privileges_allowlist_only_passes() {
        let v = judge_service_privileges(SERVICE_PRIVILEGE_ALLOWLIST);
        assert!(v.is_allowed(), "{v:?}");
        assert!(v.unexpected.is_empty(), "{v:?}");
    }

    /// 反证：八项禁止特权逐个单独出现都必须拒绝——从禁止表里删掉任何一项，这里就红。
    #[test]
    fn service_privileges_each_forbidden_one_refuses_start() {
        for name in [
            "SeImpersonatePrivilege",
            "SeAssignPrimaryTokenPrivilege",
            "SeDebugPrivilege",
            "SeTcbPrivilege",
            "SeBackupPrivilege",
            "SeRestorePrivilege",
            "SeTakeOwnershipPrivilege",
            "SeLoadDriverPrivilege",
        ] {
            let v = judge_service_privileges(&["SeChangeNotifyPrivilege", name]);
            assert!(!v.is_allowed(), "{name} 应拒绝启动：{v:?}");
            assert_eq!(v.forbidden, vec![name.to_string()]);
        }
        let v = judge_service_privileges(&["seimpersonateprivilege"]);
        assert!(!v.is_allowed(), "大小写不同也要认出来：{v:?}");
    }

    /// 白名单外的普通特权不阻断，但要报出来（启动日志里能看到），不静默吞掉。
    #[test]
    fn service_privileges_unexpected_ones_are_reported_not_fatal() {
        let v = judge_service_privileges(&[
            "SeChangeNotifyPrivilege",
            "SeCreateGlobalPrivilege",
            "SeIncreaseWorkingSetPrivilege",
        ]);
        assert!(v.is_allowed(), "{v:?}");
        assert_eq!(
            v.unexpected,
            vec![
                "SeCreateGlobalPrivilege".to_string(),
                "SeIncreaseWorkingSetPrivilege".to_string()
            ]
        );
    }
}
