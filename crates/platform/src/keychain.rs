//! #1109：macOS 身份私钥存进 data protection 钥匙串。
//!
//! - 访问组 [`ACCESS_GROUP`] 来自 daemon 的代码签名权限，由嵌入的授权文件担保
//!   （#1108 / #1110）。没有这份授权的进程（别的 App、`security` 命令、未签名的
//!   开发构建）读写都被系统直接拒绝，不弹窗。
//! - 仅本机：`AfterFirstUnlockThisDeviceOnly`、不随 iCloud 钥匙串同步（与 iOS
//!   #1114 同一组属性）。开机后首次解锁前读不到——LaunchAgent 在用户登录后才跑，
//!   那时已解锁；万一读不到，按「其他错误」拒绝启动，KeepAlive 会再拉起。
//! - 每次查询都带访问组：不带组时，没有授权的进程拿到的是「没有这一条」而不是
//!   「缺授权」，会被误判成首次启动去生成新身份。

use security_framework::access_control::{ProtectionMode, SecAccessControl};
use security_framework::passwords::{
    generic_password, set_generic_password_options, PasswordOptions,
};

use security_framework::passwords::delete_generic_password_options;

use crate::{IdentityKeyStore, PlatformError, Result, SecretBlobStore};

/// 钥匙串访问组 = 团队 ID + daemon 的 bundle id（#1110 的 helper .app）。
pub const ACCESS_GROUP: &str = "2WJUWVUJBN.com.hawkeyexb.ppass.desktop.daemon";
/// 条目的 service 名。
pub const SERVICE: &str = "com.hawkeyexb.ppass.desktop.daemon.identity";
/// 条目的 account 名：每个用户只有一把 daemon 身份私钥。
const ACCOUNT: &str = "node-secret-key";
/// #1115：配对记录（设备白名单）正本的 service 名。与身份私钥同一访问组、同一组属性。
pub const PAIRINGS_SERVICE: &str = "com.hawkeyexb.ppass.desktop.daemon.pairings";
const PAIRINGS_ACCOUNT: &str = "pairings";
/// #1115：照片库位置的正本（只有签名 daemon 写得了；config.toml 里那份只给人看）。
pub const LIBRARY_SERVICE: &str = "com.hawkeyexb.ppass.desktop.daemon.library";
const LIBRARY_ACCOUNT: &str = "library";

/// `errSecItemNotFound`：确定没有这一条——唯一映射成 `Ok(None)` 的状态码。
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;
/// `errSecMissingEntitlement`：本进程没有访问组授权。
const ERR_SEC_MISSING_ENTITLEMENT: i32 = -34018;
/// `errSecInteractionNotAllowed`：钥匙串暂不可用（如开机后尚未解锁）。
const ERR_SEC_INTERACTION_NOT_ALLOWED: i32 = -25308;

pub struct KeychainIdentityStore {
    account: &'static str,
}

impl KeychainIdentityStore {
    pub fn new() -> Self {
        Self { account: ACCOUNT }
    }

    fn query(&self) -> PasswordOptions {
        let mut q = PasswordOptions::new_generic_password(SERVICE, self.account);
        q.use_protected_keychain();
        q.set_access_group(ACCESS_GROUP);
        q.set_access_synchronized(Some(false));
        q
    }
}

/// 状态码 → 给人看的原因。`-34018` 是开发时最常见的一条（直接跑了未签名的
/// 构建），点名说清楚，免得被当成钥匙串坏了。
fn describe(e: security_framework::base::Error) -> String {
    let hint = match e.code() {
        ERR_SEC_MISSING_ENTITLEMENT => {
            "；本进程没有钥匙串访问组授权——daemon 必须以带授权文件签名的 helper .app 运行"
        }
        ERR_SEC_INTERACTION_NOT_ALLOWED => "；钥匙串暂不可用（用户未登录，或开机后尚未解锁）",
        _ => "",
    };
    format!("{e}（OSStatus {}）{hint}", e.code())
}

impl IdentityKeyStore for KeychainIdentityStore {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        match generic_password(self.query()) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
            Err(e) => Err(PlatformError::Failed {
                action: "读取钥匙串",
                detail: describe(e),
            }),
        }
    }

    fn write(&self, secret: &[u8]) -> Result<()> {
        let access = SecAccessControl::create_with_protection(
            Some(ProtectionMode::AccessibleAfterFirstUnlockThisDeviceOnly),
            0,
        )
        .map_err(|e| PlatformError::Failed {
            action: "写入钥匙串",
            detail: describe(e),
        })?;
        let mut q = self.query();
        q.set_access_control(access);
        set_generic_password_options(secret, q).map_err(|e| PlatformError::Failed {
            action: "写入钥匙串",
            detail: describe(e),
        })
    }

    fn location(&self) -> String {
        format!("钥匙串 {SERVICE}（访问组 {ACCESS_GROUP}）")
    }
}

/// #1115：钥匙串里的一条整份读写的机密数据。属性与身份私钥一致：data protection
/// 钥匙串、仅本机（`AfterFirstUnlockThisDeviceOnly`）、不同步、每次查询都带访问组。
pub struct KeychainBlobStore {
    service: &'static str,
    account: &'static str,
}

impl KeychainBlobStore {
    pub fn pairings() -> Self {
        Self {
            service: PAIRINGS_SERVICE,
            account: PAIRINGS_ACCOUNT,
        }
    }

    pub fn library() -> Self {
        Self {
            service: LIBRARY_SERVICE,
            account: LIBRARY_ACCOUNT,
        }
    }

    fn query(&self) -> PasswordOptions {
        let mut q = PasswordOptions::new_generic_password(self.service, self.account);
        q.use_protected_keychain();
        q.set_access_group(ACCESS_GROUP);
        q.set_access_synchronized(Some(false));
        q
    }
}

impl SecretBlobStore for KeychainBlobStore {
    fn read(&self) -> Result<Option<Vec<u8>>> {
        match generic_password(self.query()) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(None),
            Err(e) => Err(PlatformError::Failed {
                action: "读取钥匙串",
                detail: describe(e),
            }),
        }
    }

    fn write(&self, bytes: &[u8]) -> Result<()> {
        let access = SecAccessControl::create_with_protection(
            Some(ProtectionMode::AccessibleAfterFirstUnlockThisDeviceOnly),
            0,
        )
        .map_err(|e| PlatformError::Failed {
            action: "写入钥匙串",
            detail: describe(e),
        })?;
        let mut q = self.query();
        q.set_access_control(access);
        set_generic_password_options(bytes, q).map_err(|e| PlatformError::Failed {
            action: "写入钥匙串",
            detail: describe(e),
        })
    }

    fn delete(&self) -> Result<()> {
        match delete_generic_password_options(self.query()) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == ERR_SEC_ITEM_NOT_FOUND => Ok(()),
            Err(e) => Err(PlatformError::Failed {
                action: "删除钥匙串条目",
                detail: describe(e),
            }),
        }
    }

    fn location(&self) -> String {
        format!("钥匙串 {}（访问组 {ACCESS_GROUP}）", self.service)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 测试二进制没有访问组授权（链接器 ad-hoc 签名，无授权文件）。真实
    /// Security.framework 下读取必须是 `Err`（-34018），**不能**是 `Ok(None)`：
    /// 否则未授权的进程会被当成首次启动去生成新身份。
    /// 反证：去掉 `query()` 里的 `set_access_group`，系统回 -25300，这里变红。
    #[test]
    fn read_without_entitlement_is_an_error_not_absence() {
        // #1115：配对记录正本同理——缺授权读不到是错误，不是「没有白名单」。
        match KeychainBlobStore::pairings().read() {
            Err(PlatformError::Failed { detail, .. }) => {
                assert!(detail.contains("-34018"), "{detail}")
            }
            other => panic!("未授权读取配对正本必须报错，实际 {other:?}"),
        }
        let store = KeychainIdentityStore {
            account: "unit-test-no-entitlement",
        };
        match store.read() {
            Err(PlatformError::Failed { detail, .. }) => {
                assert!(detail.contains("-34018"), "应是缺授权：{detail}");
                assert!(detail.contains("helper .app"), "说明要点名签名：{detail}");
            }
            other => panic!("未授权读取必须报错，实际 {other:?}"),
        }
    }
}
