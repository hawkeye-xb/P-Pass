# 布局 v1 落地任务卡（2026-08-06 出卡）

> 依据 [AGENT_PROTOCOL.md §C](../../AGENT_PROTOCOL.md)。设计规范 = 本目录
> `P-Pass 布局与交互.dc.html`（浏览器打开可交互）+ `README.md` 裁决摘要。

## 卡号 T-080  级别 L2 — Android 端对齐布局 v1

**目标**：手机端 UI 对齐设计稿 v1——照片 tab = 统一时间线 + 轻过滤器；备份 tab =
恒真三元组（手机 N 张 · 已备份 M · 待备份 K）+ 可暂停 + 失败才说话；顺带修掉
两个真机已确认的缺陷：(a) 顶部横幅在待备份 > 0 时仍显示「照片都存好了」；
(b) 从未成功备份时「最后成功」显示 epoch 0（01-01 08:00）。

**范围**：只准动 `apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/**`、
`i18n/DiagText.kt`、必要的字符串资源。

**不准动**：`transport/`、`proto/`、`backup/` 逻辑层；`crates/`；`apps/desktop/`；
已有测试。

**可执行验收**：
  - 跑 `./gradlew :app:assembleDebug` → 期望 `BUILD SUCCESSFUL`
  - 状态条逻辑：待备份 > 0 时不得出现「都存好了」类文案（单测或可复现说明）
  - 反证：把「最后成功」传入 0 时间戳 → UI 必须显示「还没有成功备份过」类文案而非日期
  - 真机截图 = L3，由验收人（指挥端 adb）完成，不在本卡内

**证据要求**：报绿附命令 + 输出摘要。

**收尾**：分支提交，PR 描述列出与设计稿逐屏对照，停下等 review。

## 卡号 T-081  级别 L2 — 桌面端侧边栏四页

**目标**：桌面端由单页长滚动改为侧边栏四页（总览 / 家人与设备 / 活动记录 / 设置，
照片库并入设置）；顶部徽章只表示服务状态；连接状态下沉到每台设备行；危险操作
只出现在桌面端。

**范围**：只准动 `apps/desktop/src/**`、`apps/desktop/index.html`。

**不准动**：`apps/desktop/src-tauri/`；`crates/`；`apps/android/`；已有测试。

**可执行验收**：
  - 跑 `pnpm --dir apps/desktop build` → 期望 vite build 成功、无错误退出
  - 四页路由可达、默认落在「总览」（可复现说明或组件测试）

**证据要求**：报绿附命令 + 输出摘要。

**收尾**：分支提交，PR 描述列出与设计稿逐屏对照，停下等 review。

## 卡号 T-082  级别 L2 — 桌面 UI 还原走查修复（2026-08-06 真窗口走查后出卡）

**背景**：真窗口四页截图对照设计稿，确认 6 处实施走样（非 token 问题，token 使用正常）。

**目标**：桌面端逐项还原设计稿：
1. 窗口默认尺寸 1140×720（设计稿 deskW/deskH），加 minWidth 920 / minHeight 600
2. 总览两卡等高：`.cols` 改 `align-items:stretch`（设计稿原文如此）
3. 二维码 148×148（设计稿尺寸；生成时用 2x 分辨率保证清晰），添加设备卡内容
   水平居中（标题保持左上），「无法扫码」折叠器与 hint 跟随设计
4. 键盘焦点样式：自定义 `:focus-visible`（token 色 2px outline + offset），
   消灭系统默认蓝色焦点圈
5. 设备行按设计两行结构：首行人名/设备名加粗，次行「机型 · 连接状态」槽位
   （数据未接前显示中性占位，不许捏造「已直连」），右侧「最近备份」槽位；
   **不再渲染原始 role 字串（member）**
6. 已移除设备不再以划线尸体行全量平铺：折叠为「已移除设备 N 台」展开器，
   展开后再列（无删除线，用 ink-40 弱化）
7. 总览水位卡底部说明补全设计稿全句「……任何一边不对劲，另一边 3 天内亮红。」

**范围**：`apps/desktop/src/**`、`apps/desktop/src-tauri/tauri.conf.json`
（**仅** `app.windows[0]` 的尺寸字段）。

**不准动**：src-tauri 其余内容、invoke/IPC 契约、crates/、apps/android/、已有测试。

**可执行验收**：
  - `pnpm --dir apps/desktop build` → 退出码 0
  - 无头浏览器 DOM 断言：`.cols` computed `align-items === "stretch"`；
    QR img 渲染宽高 148；`:focus-visible` outline 非 rgb(0,95,204) 系蓝；
    设备页无删除线元素平铺（`text-decoration: line-through` 计数 = 0，折叠态）
  - 反证：把断言目标改回旧值必须红

**证据要求**：报绿附命令 + 输出摘要。
**收尾**：分支提交，停下等 review（真窗口截图复核由验收人做）。

## 卡号 T-083  级别 L2 — Android UI 还原走查修复（2026-08-06 模拟器全态走查后出卡）

**背景**：全量走查（欢迎/照片/备份/失败态，中文 locale）发现 4 处旧代码遗留干扰 +
1 处设计红线违反。设计稿唯一基准；设计稿没画的态用最小自然延伸并声明。

**目标**：
1. 删除备份页副标题「已连接 P-Pass 存储端」——设计稿备份页只有 28sp serif
   标题「备份」，连接状态不在手机端宣告（桌面设备行的职责）
2. hero 卡底部区重构：删除「随时可以备份」文案和黑色大按钮「立即备份」
   （两者设计稿均不存在）。改为：备份进行中 = 设计稿原样（进度条 6dp +
   右侧白底描边圆角 14 的「暂停/继续」按钮）；空闲态（设计稿未画，声明为
   最小延伸）= 左侧弱文案「插电 + Wi-Fi 时自动进行」+ 右侧同款白底描边
   次级按钮「现在备份」（复用暂停按钮样式，不用黑色主按钮）
3. 失败红卡去代码化：**任何原始错误串（IrohError/异常 dump）不得直接渲染**
   ——设计红线「报错永远不出现代码，先说『照片没丢』」。红卡正文只保留
   人话（当前语言单语，不再双语堆叠）；技术细节移入「查看技术详情」折叠区
   （默认收起），并确保完整错误进诊断导出路径
4. 哨兵态主按钮：配对失效（被移除/鉴权拒绝）时红卡主按钮变「重新扫码连接」
   并接入现有重扫流程；普通失败保持「再试一次」语义
5. 中英混排清理：以上改动全部走 strings.xml 双语对称（StringsSymmetryTest 绿）

**范围**：`apps/android/.../ui/**`、`i18n/DiagText.kt`、`values*/strings.xml`。
**不准动**：transport/proto/backup 逻辑层、crates/、apps/desktop/、已有测试语义
（BackupStatusTest 只许增不许改）。

**可执行验收**：
  - `./gradlew :app:assembleDebug :app:testDebugUnitTest` → 全绿
  - 新增单测：错误渲染纯函数——输入含 "IrohError{...}" 的原始错误 → 主文案
    输出不含 "{"、"kind:"、异常类名；折叠详情才含
  - 反证：断言取反必须红
  - 模拟器视觉复核 = 验收人做（假配对注入法）

**证据要求**：报绿附命令 + 输出摘要。
**收尾**：分支 `t-083-android-fidelity` 提交，停下等 review。

**挂账（不在本卡，须留结构）**：备份规则「备份哪些相册」行、照片 tiles ↑/↓
角标、大图页、onboarding 相册范围步——均等 proto owner 字段 / 相册选择功能卡。

## 卡号 T-090  级别 L2 — daemon IPC 数据面扩展（链 1 后端）

**目标**：桌面 UI 的四类真数据由 daemon 暴露：照片总数、磁盘水位、备份活动流、
每设备实时连接类型。

**范围**：`crates/daemon/**`、`crates/transport/**`（连接信息中性封装）、
`crates/storage`/`crates/core-index` 中必要的只读查询函数。

**不准动**：`apps/**`、proto 线上帧格式、现有 IPC 方法的已有字段语义、已有测试。

**实现**：
1. `status` 增 `photo_count`（assets 总数）、`disk_free_bytes`/`disk_total_bytes`
   （照片库所在卷）
2. 新 IPC `activity.list`（params: `limit` 默认 50）：从现有 assets 表按
   设备+时间窗聚合成备份批次 `[{node_id, name, at, asset_count}]`，倒序；
   **不建新表**，聚合口径注释写明（时间窗 gap 建议 10 分钟）
3. `devices.list` 每设备增 `connection` 字段：`"direct"|"relay"|"offline"|"unknown"`
   ——transport crate 内用 iroh 的 remote info 包成中性 enum 暴露（**铁律 B.1：
   iroh 类型不得越出 crates/transport**），拿不到实况时如实 `unknown`，禁止猜

**可执行验收**：
  - `just arch-check` 绿（B.1 隔离）+ `cargo test -p daemon` 全绿
  - ipc_flow 测试扩展：status 断言含三个新字段且 photo_count 与种子数据一致；
    seeded db 上 `activity.list` 返回正确聚合批次数
  - 反证：把聚合时间窗改为 0 → 批次数断言必须红（证明聚合真在工作），改回
**证据要求**：报绿附命令+输出摘要。收尾：分支提交，停下等 review。

## 卡号 T-091  级别 L2 — 桌面接真数据·第一批（链 1 前端，仅用现有 IPC）

**目标**：把 daemon **已经暴露但桌面从未消费**的数据接上 UI：
`device.watermarks`（每设备最近备份时间+张数）与 `devices.list.last_seen`。

**范围**：`apps/desktop/src/**`。
**不准动**：`src-tauri/**`、`crates/**`、不得调用任何 T-090 的新方法/新字段
（未合并，跨卡禁令）；现有 invoke 集合只准新增 `device.watermarks` 调用。

**实现**：
1. 设备行（家人与设备页 + 总览水位卡）接真数据：次行「最后在线 <人性化时间>」，
   右侧「最近备份 <人性化时间> · N 张」；无水位记录显示「还没备份过」
2. 哨兵亮红（设计稿原文行为）：最近备份 >5 天 → 行点变 ACT 色 + 右侧「需要看看」;
   数据来自 watermarks，纯函数判定
3. 人性化时间纯函数（刚刚/今天 HH:MM/昨天 HH:MM/周X HH:MM/MM-DD），
   独立成模块并配 node 可跑的断言脚本
4. 连接状态槽位保持中性占位（等 T-090 合并后另卡接线，不许提前写死）

**可执行验收**：
  - `pnpm --dir apps/desktop build` 退出码 0
  - `node` 直跑时间函数断言脚本：≥6 个边界用例（0/今天/昨天/6天/7天/去年）全过
  - 反证：把「>5 天亮红」阈值断言改 >0 天 → 必须红，改回
  - 真 daemon 实机复核 = 验收人做（本机有真存储端+真设备数据）
**证据要求**：报绿附命令+输出摘要。收尾：分支提交，停下等 review。
