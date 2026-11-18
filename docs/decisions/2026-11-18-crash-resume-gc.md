# 崩溃续传先清传输缓存，再按订单重建引用

- 状态：已采纳（产品负责人 2026-11-17，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1821#issuecomment-6949826178)）
- 日期：2026-11-17（2026-11-18 修订第 1 条的清理手段，见「理由」与「备选」）
- 关联：#1821、#1744
- 代码基线：`aafda9a0`

## 背景

手机 provider store 只是传输缓存，不是第三个照片库；持久 order 才是业务账本。初次导入后 order 已保存 mediaId/sourceVersion/contentHash，崩溃后续传由 `processExisting` 按 order 重新 lookup 并导入。

持久 store 的 hash 在崩溃后仍在，但 provider 进程内 `stored` 的 hash→External(path) 映射为空，现有 `safe` 判断因此返回 `AlreadyInStore`，外层回退 `import_by_copy`，iOS 又静默接受该回退，造成手机侧额外整份副本（#1821 实测手机存储 1.17MB → 173.4MB，违反占地 1x）。

## 决定

1. 新进程尚无任何有效传输租约，启动时先把整个 provider store 目录**整体退役**，再接受导入：
   - 在 `FsStore::load_with_opts` 之前，把 `iroh-blobs-provider` 目录 rename 到同级回收目录 `iroh-blobs-provider-retired-<pid>-<纳秒>`（O(1)，与目录里有多少数据无关），启动就绪后后台删除本进程之前遗留的回收目录；删除是 best-effort 并记日志，退役本身失败必须显式失败，不得回落复制。
   - 这是仓库既有做法（`crates/daemon/src/inbox.rs` 的 `retire_blob_store`）在手机 provider 上的同一模式：iroh-blobs 0.103.1 没有可调用的一次性 GC，`store::gc` 是 crate 私有、`GcConfig` 只能配定时轮询（`crates/daemon/src/inbox.rs:36`、`crates/daemon/src/main.rs:845` 已记录）。
   - `crates/transport` 不能依赖 `crates/daemon`，这个目录操作放在 transport 内实现，平台相关部分仍只许在 `crates/platform`。
   - 多实例仍由既有 store 独占/单实例机制兜底；退役只发生在接受任何导入之前，不能动仍在运行的其他进程的缓存。
2. 复用现有 `processExisting`：按 order 找当前文件，检查来源、版本、范围和 hash，重新建立引用与持有。文件删除/移走、修改、无权限按现有分支处理；任何不确定不得复制。
3. 桌面半截文件、续传 grant/ranges、order、协议和账本不改。重新校验可能需要读取源文件，但网络只传桌面缺失部分，不得从 0 重传。
4. iOS 不再把 `already_in_store` 当成可静默接受的复制回退，两类分开：
   - 本进程 `stored` 映射为空导致的回退（崩溃重启后的形态）：启动退役之后不应再出现，出现即按单张失败，不得复制。
   - 同进程内同一内容从另一个路径再做引用导入（`crates/transport/src/provider.rs:1707` 附近，注释写明这是既定行为）返回的 `already_in_store`：不复制、不报错，按共享引用接受，但同样要求 `ref=yes`。它不新增字节，不违反 1x。
5. 不新增路径 sidecar，不按二进制段记录，不修改 Android/iOS 订单语义。

## 范围

- `crates/transport/src/provider.rs`
- `crates/transport/tests/media_import.rs`
- `apps/ios/PPass/Live/FolderImporter.swift`
- `apps/ios/PPassTests/FolderImporterTests.swift`
- `apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowEngine.swift`
- `docs/decisions/2026-11-18-crash-resume-gc.md`

## 理由

- 本质要保证的是：传输缓存可以随时丢弃重建，但任何时刻都不得变成源文件的第二份副本。
- iroh 的标准做法是「blob 只通过 GC 删除」，缓存目录因此天然被当作可丢弃数据；一次性 GC 不可用时，业界对可重建缓存的通行做法就是启动时整体丢弃（冷启动即空缓存），而不是逐条甄别。仓库已在 daemon 侧采用同一做法，这里对齐它，不引入第二套机制。
- 逐条恢复（用 `list_temp_tags` 区分遗留条目）解决不了本卡的问题：要清的正是「本进程内存映射为空」这件事，它的后果是导入路径拿不到安全判断，而不是条目本身是否被持有。

## 后果

- 上一进程的 Owned 副本和已入库缓存全部丢弃，续传必须重新按引用供数；引用读的是源文件，不产生新字节，网络只传桌面缺失部分，因此不违反 1x。
- 回退路径（daemon 主动向手机拉取）被打断的部分数据不能跨重启续传，最多重拉一个文件——与 `crates/daemon/src/inbox.rs` 现有代价相同。
- 启动多一次目录 rename，与缓存大小无关。
- 桌面沙盒库收场后 `du` ≈ 2x 的残片属于 daemon 侧 flow-staging 清理，不在本方案范围，另开卡处理；E3 的该项判据仍由 `tools/e3/run judge ios/folder-disk-gc` 判定，本卡不拿手机侧证据替代。

## 备选

- **调用 `gc_run_once`**：不可行。iroh-blobs 0.103.1 的 `store::gc` 模块是 crate 私有，没有公开的一次性入口。
- **`GcConfig` 定时轮询**：没有同步失败信号（无法满足「清理失败必须显式失败」），且重启后可能先接受导入再回收，判不了红。
- **`list_temp_tags()` 区分崩溃遗留条目后恢复引用**：只能判断条目是否被持有，救不回「进程内 `stored` 为空」这条失忆路径，也回收不了已经误复制的 Owned 副本。
- **按二进制段记账 / 路径 sidecar**：产品定案已排除。

## 验收

- E2（红 → 修复 → 绿 → 撤销回红）：`crates/transport/tests/media_import.rs` 用**长 GC 间隔**夹具（不复用 `GC = 20ms` 的 `new_loopback_with_gc`，否则上一进程遗留的无标签 blob 会被周期 GC 自行收掉，未修复也可能绿），或直接断言 store 字节数：引用导入 → 丢弃/重建 provider（模拟重启、内存 `stored` 清空）→ 同一 path 再 import → `by_reference=true` 且 store 字节不增长；撤销修复必须回到 `by_reference=false` / 字节增长。
- E3：`tools/e3/run judge ios/folder-disk-gc <证据目录>`（判据出处即该 judge）——手机 provider blobs 增长远小于源大小、崩溃后 GC 收敛。
- 传输中强杀→重启→同一 order 重新供数：`by_reference=true`，provider 字节不增长，桌面只传缺失部分。
- 上一进程已有 Owned 副本时，启动退役先回收，不虚报 by_reference。
- 文件删除/移走、sourceVersion 改变、版本未变但 hash 改变、权限暂失分别走现有结单/新订单/等待分支，不误传、不复制。
- 同设备多文件并发、多设备同 hash、同 hash 异路径、后台启动与在途互斥、退役失败均有明确结果；Android 共用 provider 至少跑对应 contract 测试。
- 成功回执后释放持有并经验证 GC 回收；不把「尚未等一个 GC 周期」写成永久泄漏。
- `du -sh` 实测手机 provider、tmp、源目录；桌面库占盘按「后果」一节归另一张卡，不在本卡判据内。
