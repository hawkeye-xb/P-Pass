# 崩溃续传先清传输缓存，再按订单重建引用

- 状态：已采纳（产品负责人 2026-11-17，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1821#issuecomment-6949826178)）
- 日期：2026-11-17
- 关联：#1821、#1744
- 代码基线：`aafda9a0`

## 本质与根因

手机 provider store 只是传输缓存，不是第三个照片库；持久 order 才是业务账本。初次导入后 order 已保存 mediaId/sourceVersion/contentHash，崩溃后续传由 `processExisting` 按 order 重新 lookup 并导入。

持久 store 的 hash 在崩溃后仍在，但 provider 进程内 `stored` 的 hash→External(path) 映射为空，现有 `safe` 判断因此返回 `AlreadyInStore`，外层回退 `import_by_copy`，iOS 又静默接受该回退，造成手机侧额外整份副本。

## 已采纳方案

1. 新进程尚无任何有效传输租约，启动时先调用 iroh 公开的 `gc_run_once` 清掉上一进程遗留的 provider 缓存，再接受导入；清理失败必须显式失败，不得复制。多实例仍由既有 store 独占/单实例机制兜底，不能清理仍在运行的其他进程的缓存。
2. 复用现有 `processExisting`：按 order 找当前文件，检查来源、版本、范围和 hash，重新建立引用与持有。文件删除/移走、修改、无权限按现有分支处理；任何不确定不得复制。
3. 桌面半截文件、续传 grant/ranges、order、协议和账本不改。重新校验可能需要读取源文件，但网络只传桌面缺失部分，不得从 0 重传。
4. iOS 不再把 `already_in_store` 当成可静默接受的复制回退；非预期回退按单张失败。
5. 不新增路径 sidecar，不按二进制段记录，不修改 Android/iOS 订单语义。

## 范围（控制实现，不靠扩文件解决）

- `crates/transport/src/provider.rs`
- `crates/transport/tests/media_import.rs`
- `apps/ios/PPass/Live/FolderImporter.swift`
- 必要的既有 iOS 导入/回退测试文件（实现前在 issue 范围段列明）

## 验收

- 传输中强杀→重启→同一 order 重新供数：`by_reference=true`，provider 字节不增长，桌面只请求缺失部分；撤销修复回红。
- 上一进程已有 Owned 副本时，启动 GC 先回收，不虚报 by_reference。
- 文件删除/移走、sourceVersion 改变、版本未变但 hash 改变、权限暂失分别走现有结单/新订单/等待分支，不误传、不复制。
- 同设备多文件并发、多设备同 hash、同 hash 异路径、后台启动与在途互斥、GC 失败均有明确结果；Android 共用 provider 至少跑对应 contract 测试。
- 成功回执后释放持有并经验证 GC 回收；不把“尚未等一个 GC 周期”写成永久泄漏。
- `du -sh` 实测手机 provider、tmp、源目录和桌面库，符合 1x；桌面残片不拿手机侧证据替代。
