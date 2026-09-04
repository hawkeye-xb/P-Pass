# BUILD-03 Windows Release 编译 Android 专属 blobs bridge，跨平台 build 被 `std::os::fd` 阻断（L1）

> 🟠 状态：进行中 · 当前节点：`v0.5.0-test.2` Release #46 Windows lane 已实证失败；下一步：把 Android FFI bridge 严格隔离为 Android target 模块，并在 Windows cross-check 与新 test Release 验证 · 协同分支：`main`
> 级别：L1 · 阻塞：无

## 问题

`crates/transport/src/lib.rs` 无条件声明和 re-export `android_blobs`。该模块使用 Android/Unix 文件描述符 API：

```
use std::os::fd::{FromRawFd, RawFd};
```

`v0.5.0-test.2` Release #46 的 Windows lane 在编译 `transport` 时失败：`std::os::fd` 被 target cfg 排除，`File::from_raw_fd` 也不存在。Android、macOS能编译掩盖了此平台边界泄漏。

## 期望行为

Android JNI blobs provider 只在 Android target 编译和导出；其余 transport 公共 API 维持原样。Windows Release 和既有 Android provider 构建均可通过。

## 验收标准

- [ ] `cargo check -p transport --target x86_64-pc-windows-msvc` 不再编译 Android-only `android_blobs`，并通过。
- [ ] Android target 的 `AndroidBlobsProvider` 仍存在且 provider bridge 可构建。
- [ ] 反证：暂时移除 Android target gate 后，Windows check 必须重新出现 `std::os::fd` / `from_raw_fd` 失败。
- [ ] 新 test tag 的 Windows Release lane 成功；完整 Release 由 REL-05 同批验证。

## 范围

- 只准动：`crates/transport/src/lib.rs` 及 Android-only 模块编译边界所需的测试。
- 不准动：iroh-blobs 传输协议、Android provider 的单 lease / revoke 语义、Release 签名与上传逻辑。

## 阻塞与依赖

无；REL-05 同批修复后，需由同一个新的 test Release 验收完整发布链。

---

## 实施记录

- 2026-09-04：`v0.5.0-test.2` Release #46 Windows job 实证 E0432/E0599。根因定位到 `lib.rs` 的无条件 `mod android_blobs; pub use android_blobs::AndroidBlobsProvider;`，非 Windows toolchain、vcpkg 或 iroh 依赖问题。
