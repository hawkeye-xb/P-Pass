//! #1109：daemon 设备身份私钥的存取端口。
//!
//! 私钥派生 NodeId，手机只认这个 NodeId。存放处由平台决定
//! （[`crate::PlatformAdapter::identity_key_home`]）：macOS 是 data protection
//! 钥匙串，Windows / Linux 维持数据目录里的 `.ppf/identity.key`。「读到 / 没有 /
//! 生成 / 读回比对 / 拒绝启动」的判定在 daemon，端口只管存取，单测用内存实现。

/// 身份私钥的一处存放。
pub trait IdentityKeyStore: Send + Sync {
    /// 读出私钥原文。`Ok(None)` **只**表示「确定没有这一条」；读不出来
    /// （钥匙串锁定、缺访问组授权、系统错误……）一律 `Err`。调用方据此拒绝
    /// 启动——把读失败当成没有、去生成新私钥，等于静默换身份。
    /// 内容是否合法（长度）由调用方判定，这里原样返回。
    fn read(&self) -> crate::Result<Option<Vec<u8>>>;

    /// 新建这一条。只在 [`read`](Self::read) 返回 `Ok(None)` 之后调用。
    fn write(&self, secret: &[u8]) -> crate::Result<()>;

    /// 给人看的存放位置（日志、启动失败说明用），不含私钥内容。
    fn location(&self) -> String;
}

/// 本平台身份私钥放在哪。
pub enum IdentityKeyHome {
    /// 系统安全存储（macOS data protection 钥匙串）。数据目录里的旧明文
    /// `.ppf/identity.key` 不读、不迁移，身份落定后删除。
    SecureStore(Box<dyn IdentityKeyStore>),
    /// 数据目录里的 `.ppf/identity.key`（仅属主可读写）——Windows / Linux 现状。
    DataDirFile,
}
