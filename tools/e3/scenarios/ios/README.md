# iOS 场景（#1744 目录来源真机 E3）

接口与 macOS / Android 相同（`tools/e3/run`：setup / act / judge / counter / teardown）。共用助手在
`ios-lib.bashlib`（扩展名不用 .sh：test-e3.sh 的 DESC/judge 检查只针对场景文件）。

场景把 ADR（`docs/decisions/2026-11-13-local-folder-media-source.md`）「验收标准 E3」逐条做成可判定用例，
在真机（`PPASS_DEVICE` / 本机唯一在线 iPhone）对本地测试目录与 Blackmagic 实拍素材各跑真实备份闭环。
驱动模式与 `tools/ios/e3-batch.sh` 一致：App 的 DEBUG 钩子（`apps/ios/PPass/Debug/BGTestDriver.swift` 的
`PPASS_BGTEST_FOLDER_*`）经 devicectl 启动环境变量进来，状态写 App 容器 `Documents/e2e/status.json`，
脚本拉回判定；目录登记走真实 `FolderRegistry.addFolder`（Blackmagic 走真系统目录选择器，由
`PPassUITests/FolderPickerDrive` 点「我的 iPhone → 目标目录 → 打开」）。桌面端用测试沙盒
（`tools/ios/sandbox-desk.sh`，daemon --ephemeral，假 HOME 临时库），不碰本机正式桌面。

| 场景 | ADR E3 条款 |
|---|---|
| `folder-nested-reopen` | 1 本地嵌套测试目录、杀进程重开继续备份 |
| `folder-reconcile` | 2 增删改移由带对账的备份轮发现（不依赖门铃） |
| `folder-bigvideo-integrity` | 3 大视频 by_reference + 手机↔桌面 BLAKE3；截断/改一字节反证（供数期注入必须传输失败） |
| `folder-dedupe` | 4b 同一素材相册+目录 → 桌面只有一份 |
| `folder-blackmagic` | 4a Blackmagic 实拍素材经真选择器授权后完成真实备份（含同素材双来源去重） |
| `folder-disk-gc` | 5 源目录/App tmp/provider blobs/桌面库前后实测 + 崩溃重启 GC 收敛 |
| `folder-background` | 6 后台只记录系统实际行为（无进度承诺） |

跑法：`tools/e3/run ios/folder-nested-reopen …`（自动持设备锁）。第一条场景默认构建+安装当前代码
（Debug 包，dev 签名）；之后的场景传 `PPASS_SKIP_BUILD=1` 复用同一份安装。素材全部程序生成；
测试目录只碰 `foldere3-*` 前缀，不动用户相册与素材。大视频大小 `PPASS_E3_FOLDER_BIG_MB`（默认 200）。

环境变量：`PPASS_SKIP_BUILD`、`PPASS_E3_FOLDER_BIG_MB`、`PPASS_E3_FOLDER_TARGET`（Blackmagic 目录名）、
`PPASS_E3_FOLDER_MAX_MB`（Blackmagic 沙盒护栏）。
