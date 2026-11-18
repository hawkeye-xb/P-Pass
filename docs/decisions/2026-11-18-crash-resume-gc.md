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
   - 在 `FsStore::load_with_opts` 之前，把 `iroh-blobs-provider` 目录 rename 到同级回收目录 `iroh-blobs-provider-retired-<pid>-<纳秒>`（O(1)，与目录里有多少数据无关），启动就绪后删除**全部**回收目录（含本次刚退役的；与 daemon 的 `sweep_retired_blob_stores` 同口径，残留清扫删的也是全部 `blobs-retired-*`），否则上一进程的整份 store 会在 `blobs/` 下活到下次启动、被 E3 的 `provider_blobs` 算进「崩溃后收敛」而判红；删除是 best-effort 并记日志，退役本身失败必须显式失败，不得回落复制。
   - 这是仓库既有做法（`crates/daemon/src/inbox.rs` 的 `retire_blob_store`）在手机 provider 上的同一模式：iroh-blobs 0.103.1 没有可调用的一次性 GC，`store::gc` 是 crate 私有、`GcConfig` 只能配定时轮询（`crates/daemon/src/inbox.rs:36`、`crates/daemon/src/main.rs:845` 已记录）。
   - `crates/transport` 不能依赖 `crates/daemon`，这个目录操作放在 transport 内实现，平台相关部分仍只许在 `crates/platform`。
   - 多实例仍由既有 store 独占/单实例机制兜底；退役只发生在接受任何导入之前，不能动仍在运行的其他进程的缓存。
2. 复用现有 `processExisting`：按 order 找当前文件，检查来源、版本、范围和 hash，重新建立引用与持有。文件删除/移走、修改、无权限按现有分支处理；任何不确定不得复制。
3. 桌面半截文件、续传 grant/ranges、order、协议和账本不改。重新校验可能需要读取源文件，但网络只传桌面缺失部分，不得从 0 重传。
4. iOS 不再把 `already_in_store` 当成可静默接受的复制回退。transport 现在是两种不同原因共用同一个枚举，必须先把信号分开（`crates/transport/src/provider.rs:1709-1716` 的 `safe` 判断处、`:1786-1792` 的 `import_by_copy` 返回处）：
   - **崩溃失忆形态**：持久 store 有该 hash，但本进程 `stored` 没有它的记录（重启后就是这样）。启动退役之后不应再出现；出现即按单张失败，不得复制。transport 保留现有 `ImportFallback::AlreadyInStore` 表示这一类。
   - **共享引用形态**：本进程 `stored` 里该 hash 是另一条路径的 `External` 集合。这是既有行为，**保留原来的复制与测试**（`crates/transport/tests/media_import.rs:469` 的 `content_already_referenced_elsewhere_is_copied`：iroh 合并 External 路径只重开排序第一的那条，删掉它会毒掉条目，第二次导入必须复制才能保证删掉第一条后仍可供数）。transport 为这一类单独给一个枚举值（共享引用），iOS 照旧接受、但不把它当成崩溃恢复成功。
   - 取舍：这条复制不消除，因为换成「不复制」就要把「第一条路径被删后仍可供数」从成立改成供数失败；同内容异路径是少见情形，占盘代价有限。要一并消除属于产品取向，另开卡并需拍板。
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
  本方案范围内的例外是「共享引用形态」的复制（「决定」第 4 条）：同内容已经在另一条路径上以引用入库时，第二次导入要复制才能保证第一条路径被删后仍可供数。它不取消，也正因如此才把两类 `already_in_store` 分开；要取消这个例外属于产品取向，另开卡拍板后再改决定第 4 条。
  另有一种既有复制不在本方案范围：`no_path`（API 29 拿不到文件路径）本来就走 `import_by_copy`，把整份源文件复制进 store；它不是本方案引入、也不由本方案处理，这里只声明不属于上面那条不变量讨论的对象，避免把它误读成本方案的缺陷或例外。
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

- E2（红 → 修复 → 绿 → 撤销回红）：`crates/transport/tests/media_import.rs` 用**长 GC 间隔**夹具（不复用 `GC = 20ms` 的 `new_loopback_with_gc`，否则上一进程遗留的无标签 blob 会被周期 GC 自行收掉，未修复也可能绿），或直接断言 store 字节数：引用导入 → 丢弃/重建 provider（模拟重启、内存 `stored` 清空）→ 同一 path 再 import → `by_reference=true` 且**不新增 `.data` 载荷**（引用导入本身会写 outboard，判据是「无 `.data`、有 `.obao4`」，见 `media_import.rs:418-420`；`#1821` 的 `before.json` 里约 1MB 引用元数据属正常，不能写成按字节零增长）；撤销修复必须回到 `by_reference=false` / 新增整份 `.data`。
- E3：`tools/e3/run judge ios/folder-disk-gc <证据目录>`——手机 provider blobs 增长远小于源大小、崩溃后 GC 收敛。注意该 judge（`tools/e3/scenarios/ios/folder-disk-gc.sh:158-159`）还有一条「桌面库总占盘增量 ≈ 源大小」，按卡的 E3 也列着；这一项归 daemon 侧残片回收那张卡，在它修好之前本卡的 E3 **不可能 PASS**，不得改判据归属或记为通过。
- 传输中强杀→重启→同一 order 重新供数：`by_reference=true`，不新增 `.data` 载荷，桌面只传缺失部分。
- 上一进程已有 Owned 副本时，启动退役先回收，不虚报 by_reference。
- 文件删除/移走、sourceVersion 改变、版本未变但 hash 改变、权限暂失分别走现有结单/新订单/等待分支，不误传、不复制。
- 同设备多文件并发、多设备同 hash、同 hash 异路径、后台启动与在途互斥、退役失败均有明确结果；Android 共用 provider 至少跑对应 contract 测试。
- 成功回执后释放持有并经验证 GC 回收；不把「尚未等一个 GC 周期」写成永久泄漏。
- `du -sh` 实测手机 provider、tmp、源目录。桌面库占盘按上面 E3 那条处理：判据不改归属，在 daemon 残片卡修好前本卡 E3 保持红。
