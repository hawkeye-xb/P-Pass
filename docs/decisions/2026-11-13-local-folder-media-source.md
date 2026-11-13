# 本地授权目录作为照片和视频备份来源

- 状态：已采纳（三模型评审后修订；产品负责人 2026-11-13 确认采纳，[定案评论](https://github.com/hawkeye-xb/P-Pass/issues/1731#issuecomment-6850508514)）
- 日期：2026-11-13
- 关联：#1731、ARCH-01（`docs/design/2026-08-29-arch01-backup-core/`）
- 代码基线：`44b9db83`
- 范围：iOS 技术与实施；**不含 UI**

## 结论

在现有照片／视频备份链路中新增「本地授权目录」来源：用户通过系统目录选择器授权一个本地文件夹，P-Pass 递归发现其中的照片和视频，按现有 Flow 完成导入、哈希去重、传输和桌面入库。

不新增传输协议，不做通用文件备份，不为 Blackmagic 写特例，不改变现有 PhotoKit 路径。新增实现必须满足现有 `MediaSource` 与 `MediaImporter` 接口；多来源组合也只能是这两个接口的实现，不能成为新的主流程阶段。

## 背景

#1731 的外部用户需要直接备份 Blackmagic Camera 素材。「同时保存到 App 与系统相册」会产生两份大视频；仅保存在 App 或所选目录时，现有 PhotoKit 来源无法读取。

已核实的事实：

1. Apple 的目录选择器可授予单个目录及其子目录的安全作用域访问，并可保存书签供后续启动使用；官方文档同时说明覆盖未来新增内容。
2. 本机 Blackmagic Cam 3.5.30 的目录在 Files「我的 iPhone」中真实可见。
3. 独立 UIKit 探针已完成：选择 Blackmagic 目录 → 递归读取 2 个常规文件 → 保存书签 → 杀进程重开 → 恢复访问并再次读取，同一文件前 64 KiB 样本一致，测试 0 失败。
4. 先前失败不是授权失败，而是探针对子文件重复开启安全作用域；在根目录作用域内协调读取即成功。
5. `NSFilePresenter` 可提供子项变化通知，但只保证协调写入；iOS 后台不能依赖它持续监听。

证据见 #1731 的 2026-11-13 调研与真机评论。本次只比较过样本，不等于完整大文件或正式备份已经验收。

## 产品边界

### 覆盖

- 「我的 iPhone」中用户显式选择的本地目录及其所有层级的子目录。
- 目录中被系统 UTI 识别为图片或视频的文件；不能解码预览不妨碍按原字节备份。
- Blackmagic 及采用同一系统目录暴露方式的相机 App。

### 不覆盖

- 文档、音频、工程文件、元数据文件等其他类型；忽略它们，不宣称整个目录已完整备份。
- 外置盘、iCloud Drive 和第三方 File Provider，后续按同一接口另行验证。
- 通用文件备份、目录树在桌面端的复刻、源文件删除、自动清空系统相册。
- UI、Android 实施、App 被划掉后的及时后台唤醒与「拍完立即同步」。

## 决定

### 1. 固定主流程

```text
PhotoMediaSource ─┐
                  ├→ CompositeMediaSource → FlowEngine → CompositeImporter
FolderMediaSource ┘          （每次一件）        ├→ PhotoImporter
                                                 └→ FolderImporter
                                                        ↓
                                             FlowDelivery（Auto）→ Desktop Ingest
```

- 除本文明确定义的「来源暂不可用」内部结果外，`MediaSnapshot`、`MediaDetails`、`ImportResult`、`DeliveryRequest`、`flow.offer` 和桌面 ingest 不变。
- 目录来源属于持续自动备份，使用 `FlowItemSource.Auto`，不走一次性 `Picked`。
- 首版统一经 Composite 装配，避免单源与多源两条路径；「单源不需要 Composite」只是接口自由度，不另做实施分支。
- 顺序扫描各来源并合并快照；FlowEngine 仍每次处理一件，不并行跑两条完整备份链路。
- `SourceRegistry` 是配置与授权注册表，不是流程阶段。

### 2. 模块职责

| 模块 | 职责 | 不做什么 |
|---|---|---|
| `SourceRegistry` | 保存来源与文件映射：sourceId、类型、显示名、目录书签、授权状态、opaque itemId ↔ 相对路径；跨启动恢复 | 不保存订单，不复制 `BackupScopeStore` 的选择状态 |
| `FolderMediaSource` | 在根目录授权内递归枚举元数据，按媒体类型过滤，生成 `MediaSnapshot` / `MediaDetails` | 不读完整文件，不负责传输 |
| `CompositeMediaSource` | 合并各来源快照，提供稳定顺序和各自游标语义；仍实现 `MediaSource` | 不是新流程阶段，不返回部分可信结果 |
| `FolderImporter` | 按私有映射找到文件，在协调回调内读取并管理引用与授权所有权 | 不调用 PhotoKit，不删除源文件，不静默复制回退 |
| `CompositeImporter` | import 按来源分发；release 广播给全部子导入器，各自幂等清理 | 不按 contentHash 推断来源，不改变导入结果 |
| `FolderChangeSource`（可选后续） | 把目录变化接到统一变化处理 | 不负责进度，不替代对账 |

`BackupScopeStore` 继续保存选中的 `sourceId`；`OrderStore` 继续保存传输事实。目录书签和完整相对路径只放在 App 私有 Registry，不写日志、不进入 order、审计 `itemRef` 或线上协议。桌面展示所需 basename 仍沿用现有 `DeliveryRequest`，这是既有行为，不额外发送目录树。

### 3. 身份与内容版本

- 添加目录时生成稳定 UUID 作为 `sourceId`；移除后不复用。首版允许用户逐一登记多个本地目录。
- 文件的 `mediaId = "folder:<sourceId>:<opaqueItemId>"`。`opaqueItemId` 是 Registry 持久化的随机 ID，**不含相对路径**；跨重启的映射只存在 App 私有容器。
- 相对路径仅做语法规范化：分隔符与 `.` 段处理，拒绝绝对路径和 `..`。不得 Unicode/case-fold；ID 判等、去重和分页游标都按原始 UTF-8 字节，避免合并不同文件。
- 首版统一跳过 symlink 和 alias，不解析、不跟随。
- `sourceVersion` 沿用 `modifiedAtMs:size`；元数据取不全时该项目按不可得处理，不能伪装成未变化。`captureAtMs` 有修改时间则填修改时间，否则填 0，由桌面沿用现有 EXIF/mtime 回退。
- 移动／改名分配新的 opaque itemId，旧 ID 按可信扫描结果记源缺失；桌面仍按内容哈希去重。
- 原地修改保留 ID、产生新版本；导入及传输中的内容校验沿用现有规则。
- 只有根目录可访问且一次完整枚举成功后，才能把缺席文件判为源已删除。目录不可达、书签失效、授权撤销、枚举中途失败都只是「不知道」。

### 4. 每轮发现与去重

每个带 reconcile 的备份轮异步执行全量元数据对账：

1. 递归取得相对路径、UTI、修改时间、大小；按 mediaId 的 UTF-8 字节序排序并分页。
2. 忽略非图片／视频；只对新增或疑似变化的项目读取字节并计算哈希。
3. 新快照交给现有 Flow 取件与建单逻辑，不另造队列。
4. 桌面继续按内容哈希判重；同一内容出现在相册和目录中时，不重复存储。

Folder 的接口契约明确为：

- `preciseDiscovery = false`，每轮由 `inScope` 对账发现，不把 mtime 当精确水位。
- `changes(after:limit:)` 恒返回空批，目录新项不依赖 incremental changes。
- `currentPosition()` 返回稳定的 `folder-v1` 占位 `DiscoveryPosition`，仅满足协议，不表示扫描进度。
- `libraryIdentity()` 返回 nil，不因占位位置触发重置。
- 新素材在下一个 reconcile 轮被发现；普通 `foregroundMediaChange` 不等于 Folder 对账。
- 任一相关来源不可信时，Composite 的 `existingIds` 整体返回 nil（不知道），不得返回部分并集，也不得把不可用来源当空集。

Folder 的范围判断绕过共享 `since` 时间档；PhotoKit 继续走现有 `ScopeKey.inScope`。首版备份目录内现有及未来媒体。后续若增加时间过滤，必须按来源分别解释输入，不改变发现、导入或传输；现在不预留无实现的空函数。

### 5. 授权生命周期与读取

**来源暂不可用必须有独立类型。**`FolderMediaSource.lookup` 与 `FolderImporter.importMedia` 在根授权失效或根不可达时抛出 `SourceUnavailable`，不得返回 nil、`.sourceMissing`、网络错误或桌面不可达。FlowEngine 捕获后进入新的 `WAITING/sourceUnavailable`：

- 不推进 G/S，不写 `sourceMissing`，不计单张失败，不把在途 order 变成失败或源已删除。
- 首版采用保守策略：**整条 Flow 等待重新授权，PhotoKit 也暂停**。这是明确代价，避免当前单 `MediaSource` 引擎在部分来源异常时误标另一来源；按来源独立暂停是后续工作。
- 授权恢复前，`mediaAbsenceTrusted = false`，Composite 的 `existingIds = nil`，任何来源都不得被误标。

其他约束：

- 每次枚举和文件打开都在各自的 `NSFileCoordinator` 回调内完成，并使用回调提供的 newURL。security scope 负责授权，不等于对整棵目录树做协调；后续供数依赖现有 source watch 与逐块校验识别变化，不宣称协调块仍持续保护。
- 元数据扫描结束释放根作用域。导入引用与授权的持有期覆盖 provider 实际需要，并在确认、源删、失败、路径中断、取消、断开及进程重启等全部出口清理；若现有 Flow 缺少释放点，必须列入实施改动，不能只依赖 `release` 一个出口。
- 使用现有 `import_media(path:fd:)` 引用入口并验证 `by_reference = true`，不使用会复制的 `importFile`。首版引用导入失败按单张失败处理，**不静默复制回退**；`release` 由 Composite 广播，provider `ffi.release` 保持幂等。
- 每次 `startAccessingSecurityScopedResource()` 成功都必须配对 stop。解析书签遇到 `stale = true` 且根仍可用时，在当前授权内重建并原子替换；替换失败保留旧书签并记恢复未验证，不能先毁掉旧书签。
- 临时文件与 provider `blobs/`（含元数据）都纳入清理责任；崩溃重启后必须验证 GC 收敛，不能只检查 App tmp。

### 6. 变化通知与后台

首版不实现 `FolderChangeSource`，目录发现只发生在 reconcile 轮。后续若要门铃真正加速，必须显式 `markScanDirty` 并触发带 reconcile 的路径；仅调用现有 `foregroundMediaChange` 不足以让 Folder 发现新项。

通知生命周期由本方案自己限定：后台租约结束或取消后停止新协调访问，完成或取消当前回调再注销，回前台可重建。通知丢失仍由对账兜底，不宣称系统要求所有 App 一进后台就注销。

App 被用户划掉后，不保证系统会及时唤醒传输；这不是本方案要掩盖或承诺解决的限制。

## 异常口径

| 情况 | 处置 |
|---|---|
| 书签不存在、损坏或授权被撤销 | 抛 `SourceUnavailable`，整条 Flow 等待；不推进 G/S、不计失败、不写源已删除 |
| `stale = true` 但根仍可用 | 在当前授权内重建并原子替换书签；替换失败保留旧书签并记恢复未验证 |
| 根目录授权失败或目录不可达 | 同 `SourceUnavailable`，不能假报 0 项，Composite 的 presence 对账整体返回 nil |
| 枚举中途失败 | 保留已推进的扫描进度和已建订单，本轮报错、扫描保持脏，下轮从头；不据此判删除 |
| 完整枚举后文件缺席 | 该项目记源缺失；已确认桌面副本不动 |
| symlink / alias | 首版跳过，不计失败，不跟随 |
| 非图片／视频 | 忽略，不计失败 |
| 快照后文件被改或删除 | 走现有导入校验、源变化／源缺失语义，不确认旧版本 |
| 非授权原因的单文件读取失败 | 沿用现有单张失败与重试预算，不拖住其他项目 |
| 引用导入失败 | 单张失败，不静默复制回退；所有出口清理引用与授权 |
| 书签保存失败 | 不启用该来源，向调用方报错，不假装登记成功 |
| 相册与目录内容重复 | 桌面按哈希去重，订单仍按现有语义完成；release 广播，不按 hash 分发 |

## 实施拆分

1. **契约与测试先行**：固定 opaque ID、UTF-8 排序、版本、Folder 游标、`SourceUnavailable`、presence 合并、授权与全部资源出口；先写会红的合同测试及反证。
2. **目录单源适配**：实现 `SourceRegistry`、`FolderMediaSource`、`FolderImporter`，使用 path+fd 引用导入，不接 UI。
3. **组合与必要的引擎缝**：实现 `CompositeMediaSource`、`CompositeImporter`、`WAITING/sourceUnavailable` 及全出口资源释放。首版统一经 Composite，保持 PhotoKit 回归不变。
4. **真机闭环**：本地测试目录和 Blackmagic 各跑一次完整备份，含大文件、重启与异常用例。
5. **可选加速**：确有必要再接带 reconcile 的 `FolderChangeSource`，不得先以监听替代对账。

`FlowEngine.swift` / `FlowTypes.swift` 虽不在核心名单，上述引擎缝仍是明确改动，不得再宣称只新增适配类。若需要修改 `OrderStore.swift`、`crates/proto/**` 或其它核心文件，必须重新按人控卡评审，不得借本方案直接改。

## 验收标准

### E1 / E2

- Registry 往返、重启恢复、书签写失败、stale 刷新及刷新写失败、路径语法规范化、Unicode 不折叠、symlink/alias 全拒、嵌套目录与类型过滤。
- Folder `changes` 恒空、`folder-v1` 占位、`libraryIdentity = nil`、`preciseDiscovery = false`；新项只在 reconcile 轮出现。
- `SourceUnavailable` 不推进 G/S、不计失败、不写源缺失；整条 Flow 等待时，PhotoKit 也不得被误标或误传。
- Composite 在 Folder 撤权、PhotoKit 正常时整体返回「不知道」，两个来源的 CONFIRMED 都不得被误标；恢复后再判定。
- `release` 广播且幂等；确认、源删、失败、路径中断、取消、断开、进程重启均释放引用与授权，provider `blobs/` 及元数据无泄漏。
- 协调回调使用 newURL；去掉子文件协调后相应测试变红。审计包、itemRef 与额外 mediaId payload 不含相对路径。
- 反证：撤销目录授权绝不能判源已删除或 UNRECOVERABLE；撤掉根目录读取、引用导入或任一释放路径后相关测试必须变红；删除一个已确认文件再运行，不能删除桌面副本。

### E3

- 在真实本地测试目录中选择嵌套素材，杀进程重开后仍能读取并继续备份。
- 新增、移动、改名、删除和修改素材后，元数据对账能发现；不依赖门铃才能补齐。
- 用代表性大视频完成完整流式备份，确认 `by_reference = true`，手机源文件与桌面入库文件 BLAKE3 一致。对测试副本故意截断或改一字节必须失败，不得确认。
- Blackmagic 实拍摄素材经目录来源完成真实备份；同一素材同时经相册与目录出现时，桌面只有一份内容。
- 前后实测源目录、App 临时目录、provider `blobs/`（含元数据）和桌面库目录，无未登记占盘增长；崩溃重启后再次核对 GC 收敛，测试不删用户素材。
- 后台只记录系统实际行为，不据此宣称「拍完立即同步」。

## 理由

本质上是增加一个数据源，而不是增加一条传输协议。Apple 已提供用户显式授权、递归访问和书签恢复的标准机制；ARCH-01 已提供来源接口、逐件 Flow、内容哈希去重与对账兜底。方案以来源适配与组合为主，只在「来源暂不可用」和「全出口资源释放」两处补必要的引擎缝，不用一个来源故障破坏另一来源或既有确认事实。

目录通知只能提速，元数据对账才能保证不漏；只在疑似变化时读字节，避免把「全量对账」误解为「全量重读」。首版收窄到本地目录，是为了让已实证的授权模型先完整闭环，不把云端占位、外置盘和不同 provider 的行为混进同一批验收。

## 后果与代价

- 每轮需要递归读取目录元数据；大目录下的开销必须通过后续实测决定是否优化，不能牺牲对账正确性。
- 目录授权失效时首版整条 Flow 都会等待，包括 PhotoKit；这是用可用性换取不误标、不丢失的明确取舍，后续再做按来源隔离。
- Registry 需要额外保存 opaque itemId 与相对路径的私有映射，防止审计把目录结构带到桌面。
- 引用导入失败的文件首版会失败而不是自动复制，覆盖率必须由真机验证；不能用永久第二份换成功率。
- 文件移动会产生新 ID，可能多一次哈希和 offer，但桌面不会重复占盘。
- UI、Android、外部 provider 和后台实时性仍是独立工作，不能借本方案宣称完成。

## 备选（未采纳）

- **先保存到系统相册**：会产生用户明确不接受的第二份大视频。
- **只做系统照片／文件选择器手选**：是补充入口，不能形成持续自动来源。
- **扩展成任意文件备份**：超出照片和视频的产品边界，也会改变展示、恢复与目录语义。
- **另建目录专用传输管线**：破坏现有订单、去重、失败与验收模型，收益没有依据。
- **只监听目录变化**：直接写入和后台场景会漏，必须保留元数据对账。
- **每轮全量读取并哈希**：无必要 IO；先比较元数据，只有疑似变化才读字节。
- **把授权故障当源已删除、网络失败或单张失败**：会污染确认事实、游标与失败预算，禁止。
- **用永久复制规避引用导入或释放责任**：违背 1x 占盘原则；首版宁可让该项目失败并保留明确证据。
