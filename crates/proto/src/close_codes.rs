//! #1122 / #1119：桌面在连接层发出的 QUIC 应用关闭码——跨端注册表。
//!
//! 关闭帧在 TLS 握手之后发出，经桌面身份认证，与 `not_paired` 应答同样可信。
//! 手机只在关闭帧来自它记录的那台电脑（拨号对象的 NodeId）时，把下面两个码
//! 当作「未配对」处理（被拒即清理）；其它关闭原因、超时、网络断、未知关闭码
//! 一律按「连不上」处理。取值只在这里定义：transport 引用这里，两端手机的
//! 契约测试读 `close_codes_registry` 快照核对。

/// 接受连接时因为「没有配对记录、也不在配对窗口内」被拒（transport 准入钩子）。
pub const NOT_PAIRED: u32 = 401;
/// 已有连接因为这台设备的配对记录被删除而被关（`IrohTransport::close_peer`）。
pub const UNPAIRED: u32 = 410;

/// 注册表：(关闭码, 线上原因串)。原因串同时是关闭帧里的 reason 字节。
pub const ALL: &[(u32, &str)] = &[(NOT_PAIRED, "not_paired"), (UNPAIRED, "unpaired")];

/// 这个关闭码是不是「未配对」——手机据此清理自己这一侧。
pub fn means_not_paired(code: u64) -> bool {
    code == u64::from(NOT_PAIRED) || code == u64::from(UNPAIRED)
}

// probe: core-review gate check (#1187), do not merge
