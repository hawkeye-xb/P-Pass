# P-Pass 实施进度

> 按完成时间倒序排列。每卡: `DONE` + 一行摘要 + 验收输出摘录。

| 卡片 | 日期 | Commit | 状态 | 摘要 |
|------|------|--------|------|------|
| **双机跨公网验证** | 2026-07-30 | fee8f3e | DONE | **第一次真实互联网双机全剧本**：阿里云 daemon（Ubuntu 24.04，产物二进制，UDP 41145 钉安全组）×办公 Mac testclient，跨公网全部通过——①配对（QR+远端 IPC 抽象socket 确认+白名单落表）；②**backup 200 文件 5.9s**（含去重协商+**阿里云反向穿透办公 NAT 拉取 200 blob**——观察地址+UDP 打洞，印证 H-04 v4 打洞结论）；③幂等重跑缺 0 零传输；④browse 181 项（=200 去重后）分页无重复+缩略图解码 OK（**Linux libheif 管线实战工作**）；⑤吊销→revoke-check 正确拒绝→backup 被拒；⑥logs.export；⑦磁盘 181 文件=索引。配套基建：**artifacts.yml**——push 即出 Linux 二进制强推 `bin-linux-x64` 孤儿分支（纯 git 分发，云机 `git clone -b` 秒级拿产物，替代 2 核小机 40 分钟编译）；`PPF_BIND_ADDR` 配置钉端口。**新发现记账**：①QR 初始地址段是内网 IP（iroh 启动瞬间未完成公网地址探测——与 H-04 Android probe 缺陷④同源！需 PPF_ADVERTISE_ADDR 或等 relay ready 再出 QR，本轮手工构造公网地址验证）；②Linux 的 IPC socket 在抽象命名空间（连接用 `\0`+名字，非 /tmp 文件——冒烟脚本需适配）；③自报地址（同网直连）与观察地址（跨 NAT 打洞）两机制互补，各有生效场景。H-04 旧 iroh-probe 监听端已停替换为 daemon。 |
| **狗粮冒烟 #1** | 2026-07-30 | 19ae7c2 | DONE | **第一次生产形态真机运行**（release 二进制、真实网络栈、三进程分饰：daemon=狗粮机/testclient=手机/IPC=托盘 agent），实验室测试永远暴露不了的 5 个真 bug 全修：① 首启崩溃（.ppf 目录未建）；② **后台运行自动秒拒一切配对**（stdin EOF 被当"非 y"——现 EOF 即退出控制台确认，只走 IPC）；③ 无日志（tracing subscriber 接 stderr/RUST_LOG）；④ **QR 无地址段**——办公网屏蔽 n0 发现服务扫码连不上；PeerAddr 获得字符串序列化（base64url JSON），QR 加 `&a=<addr>`，扫码即连零发现依赖；⑤ 反向拉取依赖"入站观察地址"时序敏感——**BackupManifest 加 provider 字段（自报地址，线兼容）**，testclient 身份持久化（testclient.key）+ daemon 地址 sidecar。产出 `tools/dogfood-smoke.sh`：配对→备份→幂等→浏览→吊销→日志导出全剧本一条命令，**agent 可无人化执行**（狗粮机验收方式，人类裁决落地）。真机通过：配对+IPC 确认、backup 50 去重 46、幂等重跑零传输、browse 分页+缩略图、吊销即拒、logs.export 脱敏。**已知问题（记录在案）**：同机反向拨号在配置的 relay 不可达时间歇超时——T-004 默认端点写了 H-01 规划域名但 H-07 未部署，**未部署的 relay 域名会毒害路径协商**（`PPF_RELAY_URLS=""` 缓解）；真双机验证移交 Mac mini 部署。 |
| **T-035** | 2026-07-30 | — | DONE | 遥测客户端（手册 §8 事件字典 v1 原样实施）：`telemetry.rs`——四事件逐字典（conn{path,ipver,ms,fail_stage,country,isp_hash}/backup_session{files,bytes,dur_s,resumed,trigger}/first_byte{ms,kind}/daemon_alive{uptime_h,os,ver}），每事件带公共字段 anon_id/ver/ts；**anon_id 首启随机 16B 持久化**（纯随机，与硬件/用户/路径零关联）；批量队列每 5min flush；发送失败丢弃不重排（尽力而为，坏端点不能撑爆内存）。**`enabled=false` 的零网络承诺做到根上**：record 门口即丢、flush 直接返 0、run 不起定时器、**连 anon_id 都不铸造**（有测试钉死）。main.rs wiring + 24h daemon_alive 心跳。**新依赖待人类追认**：reqwest@0.12（rustls，无默认 tls）。验收（卡面两点全中）：**mock HTTP server 收到批量并逐字段 schema 校验绿**（数组 4 事件、公共字段齐、字典字段抽查、无路径样字符串）+ **关闭开关后零请求断言绿**（record+flush 后 mock 计数=0）；全仓 **161 测试绿**；just ci + cargo deny 绿。 |
| **T-034** | 2026-07-30 | — | DONE | IPC 本地服务 + 诊断聚合（ADR-012）：`ipc.rs`——interprocess 本地 socket/named pipe（跨平台无 cfg，守 B.2），**每次启动随机 32B 令牌写数据目录 ipc.token**（内容=socket 名+令牌，UI 凭它发现并认证 daemon）；线格式=行分隔 JSON（首行令牌，**错令牌静默断连+记 ipc.bad_token 诊断事件**，之后 Req/Resp 各一行）。七方法全实装：status（状态机快照+设备/待确认计数）/pairing.start（出 QR）/pairing.confirm（按设备名或队首裁决，接 T-031 pending 队列——**owner 确认队列自此归 IPC 所有**，托盘 UI 与过渡期控制台走同一 API）/devices.list/device.revoke（吊销记审计 actor=NULL=本机 owner 经 IPC）/folder.set（写回 config.toml 重启生效）/**logs.export**（打 zip：diag_events.json+devices.json，**路径脱敏 HOME→`<DATA>`，设备只留 NodeId 前 4 字节**）。`diag_agg.rs`——持有 T-003 纯状态机（子系统喂事件/IPC 读快照）+ **diag_event 30 天环形清理**（storage 新增 prune_diag，daemon 每 6h 跑）。main.rs 全量 wiring。**新依赖待人类追认**：interprocess@2（本地 socket 标准件）、zip@5（导出打包）；deny 放行 0BSD（interprocess 传递，零条款 BSD）。验收（卡面两点全中）：**4 个真实 local socket 集成测试**——status/devices/revoke 往返、**错令牌不回话且落诊断**、pairing.start→设备敲门→IPC confirm→device 行落表、**zip 抽查：断言导出内容不含真实 HOME 路径且含 `<DATA>` 替代** + diag 环形/状态机/脱敏单测；全仓 **156 测试绿**；just ci + cargo deny 绿。 |
| **T-033** | 2026-07-30 | — | DONE | 时间线/缩略图/票据服务端：`query.rs` QueryEngine——`timeline.page` 直走 repo keyset 分页；`thumb.get` 缓存命中直读文件、未生成即时生成（spawn_blocking + **5s 超时回内置占位图**，UI 永不干等；结果回写 thumb_state 1/2）；`asset.meta` 单资产；`asset.blob_ticket` 幂等 import 原图进 blob store 出 iroh-blobs 票据。**结构性收尾**：transport listen 循环按 ALPN 分流——`Blobs::attach_to_listener()` 注册 handler，`ppf/blobs/1` 连接直接交给 blobs 协议、ctrl 走应用层（T-021 埋的"一个 endpoint 一个 accept 队列"注释到期兑现；纯 provider 场景保留独立 serve()）。daemon 的 blob store 单例 Arc 共享给 backup+query（两个句柄开同一 store 会撞 redb 锁）。缩略图线格式：proto 新增 `ThumbData{jpeg_base64}`（ctrl JSON 帧内 base64，缩略图几十 KB 远低于 16MiB 帧上限；原图走 blobs 不走 ctrl）。storage 新增 `set_thumb_state` 最小 API；media-codec 公开 `placeholder_jpeg(size)`。main.rs 双 ALPN wiring；testclient `browse --limit --node` 实装（遍历校验无重复+抽查缩略图）。**无新第三方依赖**（base64 树上已有，daemon 直接声明）。验收（卡面三点全中）：**browse 遍历 500 资产**——limit=37 蛇形分页**无重漏恰好 500**、**500 张 256px 缩略图全部解码为有效 JPEG 且最长边≤256**、**抽 3 个原图凭票据 pull 后 BLAKE3 一致且逐位相同**（4.2s）+ 未知 hash 立即回占位图测试；全仓 **148 测试绿**；just ci + cargo deny 绿。 |
| **T-032** | 2026-07-30 | — | DONE | 备份接收管道（§5.1 服务端半边）：`backup.rs` BackupEngine——begin（重置会话，幂等）→ manifest（对 items 逐个查索引回 missing，**重复/乱序 manifest 安全：missing 永远按当前索引现算**；纯 hashes 无元数据也回查重答案但不可拉取）→ commit（对已声明且仍缺失的 hash **逐个从该设备拉取** → export 到 `.ppf/staging/` → ingest 走 T-011 全链含审计 → 全部成功后推水位 set_watermark(generation)）。**幂等收敛**：崩溃/断连后重跑 commit——已入库的直接跳过、部分拉取的 blob 断点续传（iroh-blobs）、staging+create_new 保证 originals 永无半成品。**两项施工裁决**（见决策记录）：①传输方向用"存储端拉取"实现"客户端推送"语义；②proto 扩展 BackupItem/generation（旧帧字节不变）。router 接 backup.\*，失败统一 INTERNAL/err.backup_failed（新 msg_key 双语："这一批备份没有完成——会自动重试，已传的数据不会丢"）。transport 配套：入站连接自动登记对端观察地址（反向拨号不依赖发现服务，有专门测试钉住）+ `Blobs::fetch_from/export_to/import`。main.rs wiring；testclient `backup --files N --node <hex>` 实装。**已知债**（注释+此处记录）：blob store 与 originals 双份磁盘占用，GC 归硬化卡。验收：**500 混合文件（jpg/mp4，每 10 个 1 个重复内容）端到端**——首跑 missing=450=去重数、**asset 计数=去重后数** ✓、水位=generation ✓、二跑 missing=0 无变化 ✓（3.0s）；**中断重跑最终一致**——客户端只提供一半文件模拟中途死亡，commit 失败留下部分入库，恢复后重跑只补余量，且**删库 rebuild 后索引与 originals 逐字段一致（T-012 守护测试兼任备份管道的一致性 oracle）** ✓（1.2s）；全仓 **146 测试绿**；just ci + cargo deny 绿。 |
| **T-031** | 2026-07-30 | — | DONE | 配对流（§2.2）：`pairing.rs`——`start(token, now)` 记 32B 一次性令牌（TTL 600s）出 QR 串 `ppf://pair?node=<hex64>&t=<hex64>`；入站 PairRequest 校验令牌（**第一次使用即消耗，无论后续成败——重放在 owner 还没点确认时也拒**；过期拒；坏格式拒）→ 挂起进 owner 确认队列（mpsc channel，UI 后接 T-034/T-041）→ 确认后写 device 表 + 审计 `pair.accepted`（actor=设备）。安全细节：网络侧永远给不出 owner 角色（只认 member/viewer，其余一律降为 member）；设备名消毒（控制字符剥离、64 字符上限、空名兜底）；所有拒绝对外同一张脸 NOT_AUTHORIZED（探测者学不到失败在哪一步）。router 接 `pair.request` dispatch；`main.rs` 启动即出一张 QR（getrandom 系统熵），**控制台 y/N 确认——绝不默认放行**（托盘 UI T-041 前的过渡）。testclient `pair --token <ppf串>` 实装。**新依赖待人类追认**：getrandom@0.3（令牌熵，iroh 树上已有）。验收（卡面三点全中）：**全流程绿**（QR→请求→确认→device 行 role=member→PairAccepted 带存储端名→审计落表）、**过期令牌拒绝绿**（发行时间倒拨 11 分钟）、**重放拒绝绿**（第二台设备同令牌被拒且不入白名单）+ owner 拒绝不写表测试；全仓 **142 测试绿**；just ci + cargo deny 绿。 |
| **T-030** | 2026-07-30 | — | DONE | daemon ALPN 路由 + 白名单检查点（§2.3"没有其他任何认证机制——简单性即安全性"）：`authz.rs` 纯函数检查点——未配对 NodeId 只许 hello/pair.request（配对之门），**吊销即拒连连 hello 都不给**；权限表 viewer=浏览+诊断（timeline/asset.meta/thumb/blob_ticket/diag）、member +backup.\*、owner 全部；拒绝一律 `Resp{NOT_AUTHORIZED}`，msg_key 区分 err.not_paired（没配过对）/err.not_authorized（吊销或越权），**发响应→关流→记 diag_event(authz.denied)** 三连。`router.rs` 接入循环：每流一请求，hello 实装（回 proto_ver+capabilities+设备名，能力协商从第一版存在），已授权但未实装的方法回 INVALID_REQUEST/err.unsupported（新注册 msg_key 含中英文案）。`main.rs` 生产 wiring（config→Db→IrohTransport→Router.serve）。**testclient revoke-check 实装**：`--node <hex>` 拨号存储端发 timeline.page，收到 NOT_AUTHORIZED = 检查点在岗 = exit 0（CLI 走 n0 发现的路径未真机冒烟——办公网出网受限，逻辑与离线集成测试同源，T-031 配对冒烟时一并验）。配套最小 API：storage `get_device(node_id)` + diag_repo（append_diag/list_diag，环形清理归 T-034）。**无新第三方依赖**。验收：**4 个真实 iroh 回环连接上的授权集成测试**（未配对拒+diag 落表、未配对 hello 放行、viewer 越权拒/浏览到达 dispatch、吊销后立即拒）+ 6 authz 矩阵单测 + diag_repo 测试，全仓 **135 测试绿**；daemon 覆盖率 84.49% 行；just ci + cargo deny 绿。 |
| **T-021** | 2026-07-30 | — | DONE | transport blobs.rs：iroh-blobs 0.103 封装——`push(hash, path)`（入库并出 ticket；哈希与 core-index 索引哈希不符=文件被改动，报错不静默换键）/`pull(ticket, dest)`（fetch 只取缺失区间=断点续传透传，BLAKE3 逐块验证，export 落盘）/`local_bytes`（诊断+断点证据）/`serve`（Router 挂 `ppf/blobs/1`；daemon T-030 时 ctrl 面并入同一 Router——一个 endpoint 只有一个 accept 队列，随代码注释）。**断连注入双测试**（一次真 kill 的两个可分离命题分开钉死）：① 崩溃安全——50MB 传输中 abort 接收任务（无任何告别），新 endpoint 重开同一 store，pull 补完且逐位一致（崩溃留下多少持久字节是 store 批处理的时序自由度，只记录不断言）；② 续传确实生效——确定性播种 8MiB 已验证 bao 前缀（复刻 iroh-blobs 自家测试工法 create_n0_bao），断言 local_bytes 恰为 8MiB 后 pull 只补缺失并校验。**新依赖待人类追认**：iroh-blobs@0.103（卡片钦定）；dev: bao-tree@0.16（播种用，与 iroh-blobs 同版本保证编码一致）；deny 放行 Apache-2.0 WITH LLVM-exception（构建期传递依赖）+ ignore RUSTSEC-2023-0089/2024-0370（iroh-blobs 传递,unmaintained 信息级,无升级路径）。验收：`nextest -p transport --retries 0 --test-threads 1` **连跑 5 次 16/16 全绿零 flake**；50MB kill→重启→续传→BLAKE3 一致 ✓。 |
| **T-013** | 2026-07-30 | — | DONE | core-media + media-codec 缩略图管线：`exif_meta.rs` 全字段 EXIF（taken_at/宽高/方向 1..8，越界丢弃；坏输入一律降级为默认值不报错）——**ingest 已按 T-011 预告换用 core-media**，kamadak-exif 从 core-index 移除；`decode.rs` JPEG/PNG/GIF/WebP 走 image-rs + EXIF 方向摆正，HEIC/HEIF 走 libheif（自带旋转变换）；`thumb.rs` `make_thumbs(hash, src, thumbs_root)` 生成 256/1024 双档到 `thumbs/<hash前2>/<hash>.{256,1024}.jpg`（§4.2 布局），**不 panic 不 Err**——任何失败写内置占位图（运行时生成的灰色方框，无捆绑资产）+ `Placeholder{reason}` 返回（调用方记 thumb_state=2），临时文件+rename 原子写不留半成品，小图不放大；`ffmpeg.rs` 视频首帧（发现顺序 PPF_FFMPEG→exe旁tools/→PATH，双平台名字都试避免 cfg）；`pool.rs` 低优先级线程池（thread-priority 尽力降级，可配并发）；`tools/fetch-ffmpeg.sh` 三平台静态下载。**偏差注记**：libheif 用系统库（brew/apt，CI 已加 libheif-dev+ffmpeg 步骤），卡面 vendored feature 留给 T-071 发布卡（静态捆绑需连 libde265，属发布管线事项，Rust API 完全一致）。**新依赖待人类追认**：image@0.25（关默认 feature 裁掉 AVIF 编码器——不用且其 libfuzzer-sys 带 NCSA 许可）、libheif-rs@2、thread-priority@3、tempfile@3（转正式依赖）。验收：**S-05 fixtures 全量 200 文件（80 JPEG+60 HEIC+60 MP4）failed=0**（33s）；损坏/缺失文件→占位图且 reason 带文件名（测试钉死）；EXIF 方向 6 旋转正确；提交微型夹具 tiny.heic(621B)/tiny.mp4(6.4KB) 保 CI 全格式覆盖；覆盖率 85.84% 行；arch-check 绿（无平台 cfg 泄漏）。 |
| **T-012** | 2026-07-30 | — | DONE | ADR-006 守护测试：`rebuild(db, library_root)` 清 asset 表→全量重扫 `originals/` 入库，索引每个字段从文件树重推导——src_device 从 `<deviceId>` 目录名解码、taken_at 走与 ingest 相同的 EXIF→mtime 规则、media_type 按扩展名推断（客户端提供的 MIME 与扩展名不符时不可恢复，已注明为接受的漂移；added_at/thumb_state 为索引元数据不参与一致性）。**配套偏差修正**：T-011 的设备目录曾取 NodeId 前 8 字节 hex，导致重建无法恢复完整 32 字节 src_device（违反 ADR-006"索引可重建"），现改为完整 64 hex 字符——与详细设计 §4.2 `originals/<deviceId>/` 字面一致，T-011 测试常量同步更新（属契约对齐，非弱化）。手工塞入 originals 的文件（不合规范布局）也收录，src_device 记空=来源未知；磁盘上同内容多份收敛为一行（字典序首路径胜出，确定性）；隐藏文件跳过；无 originals 目录=空库不报错；rebuild 幂等（在活索引上跑两次结果一致）；整次重建记一条审计 `index.rebuild` actor=NULL（对账语义，审计裁决）。storage 新增最小 API `clear_assets()`（仅 rebuild 使用）。**无新依赖**（测试内自写 xorshift 确定性 PRNG，不引 rand）。验收：契约测试**随机 50 文件库（双设备、EXIF/无 EXIF 混合、撞名 -N 后缀）→ ingest→dump→换全新空库→rebuild→dump 逐字段一致**绿；外部塞文件收录测试绿；nextest 全仓 **36 测试全绿**（core-index 24 + storage 9 + 其余）；覆盖率 `cargo llvm-cov -p core-index` **87.01% 行**（≥80% ✓，rebuild.rs 单文件 91.37%）；`just ci` + `cargo deny check` 全绿。 |
| **T-011** | 2026-07-30 | — | DONE | core-index crate：`ingest(IncomingFile) -> IngestOutcome{New(rel_path)\|Duplicate}` 全链——流式 BLAKE3（64KiB 块恒定内存）→查重→落 `originals/<设备前8字节hex>/<yyyy>/<mm>/`（同名冲突 `-1`/`-2` 后缀，create_new 原子占名防并发撞名）→写 asset 行(thumb_state=0)→**审计到设备粒度**（ingest.new/ingest.duplicate，落审计裁决）。taken_at=EXIF DateTimeOriginal（缺失回退 DateTime，再回退 mtime；EXIF 无时区按 UTC 解释保跨机稳定）。防御：file_name 只取末段（路径穿越进不了库外）；insert 撞唯一键=并发同内容竞态→回滚已落文件返回 Duplicate（索引与 originals 永不失联）；I/O 错误一律带路径（人话报错裁决）。timeline.rs 为 storage 分页的领域门面。**EXIF 解析注**：本卡仅内联读时间线键（kamadak-exif），完整 EXIF（宽高等）按计划归 T-013 core-media，届时 ingest 换用之。**新依赖待人类追认**：blake3@1（契约指名）、kamadak-exif@0.6（详细设计 §4.3 指名）、time@0.3（日历换算）；dev: proptest@1（契约指名性质测试）、tempfile@3。验收：nextest **18 测试全绿**（含契约点名的 2 个 proptest：同内容任意两次 ingest 必 Duplicate 且仅 1 行；时间线游标严格单调无重无漏，含 taken_at 重值/NULL 平局）；EXIF 用测试内手工构造的最小 JPEG-APP1/TIFF 验证（2024:05:06 → 落 2024/05 目录且 taken_at 精确）；覆盖率 `cargo llvm-cov` **85.08% 行**（≥80% ✓）；`just ci` + `cargo deny check` 全绿。 |
| **T-010** | 2026-07-29 | — | DONE | storage crate：`migrations/0001_init.sql` 按架构 §5 **v1.1** 建五表（asset/device/backup_watermark/diag_event/**audit_log**——审计表系人类当日裁决新增，见决策记录）；sqlx 连接池封装（`Db::open` WAL 模式 / `open_in_memory` 单连接防多库陷阱）；repo 方法契约齐全：insert_asset/get_asset/timeline_page + upsert_device/list_devices/revoke/set_watermark/get_watermark + append_audit/list_audit；游标=(taken_at,hash) 复合键 base64url(8B BE+32B)，keyset 分页，NULL taken_at 按 0 排序，同秒并列按 hash 破序保证全序。细节：upsert_device 不会静默解除吊销（revoke 单向，有测试钉住）；audit 外部变动 actor=NULL 如实记"检测"不冒充归因。**新依赖**：sqlx@0.8（人类已批）、base64@0.22（游标编码，契约指名 base64，人类已批"标准件不自研"）。验收：9 测试绿含迁移从零执行、**100 条翻页无重无漏**（7/页×15 页,含 NULL 与同刻并列）、吊销后 list 反映、非法游标报错不 panic；`just ci` + `cargo deny check` 全绿。 |
| **T-020** | 2026-07-29 | — | DONE | transport crate：§3.1 trait 签名逐字实现（listen/connect/conn_info）+ iroh 1.0 实现 + ALPN 常量 `ppf/ctrl/1`/`ppf/blobs/1`；ConnInfo 分类为纯函数（conninfo.rs，8 单测——吸取 probe ipver 缺陷教训：分类器必须有独立测试），Lan 判定按地址性质（私网/回环/链路本地）而非 RTT 启发式；`TransportConfig::loopback()` 全离线（无 relay/无发现），CI 无需外网；`ConnInfo.path: Option<PathKind>`（None=无活连接，设计选择随代码注释）；BiStream 帧收发与 proto::codec 共享 4B LE 长度前缀线格式。**新依赖待人类追认**：iroh@1（ADR-001 卡片钦定）、tokio@1、futures-core@0.3；deny.toml 放行 Unlicense/Zlib/CDLA-Permissive-2.0（均宽松，iroh 传递依赖）+ ignore RUSTSEC-2024-0436（paste 停维护，信息级，无升级路径）。验收：回环集成测试两 endpoint 经 ctrl ALPN 收发 **1000 条 proto 消息**（id 关联+payload 回显逐条校验）0.31s 全过，`ConnInfo.path==Lan`；transport 13 测试绿；`just ci`（fmt/clippy -D warnings/test/arch-check）+ `cargo deny check` 全绿；proto 25 快照原样未动。 |
| **T-005** | 2026-07-28 | — | DONE | testclient 骨架：pair/backup/browse/revoke-check 四子命令占位（clap derive），连接 daemon 失败输出人话错误（含下一步指引），真实逻辑随 P3 各卡实装。新依赖 clap@4（生态标准 CLI 解析，**待人类追认**，过 cargo-deny）。验收：`testclient --help` 列出四子命令；`cargo build` 绿；2 单测（子命令齐全 + clap 定义自检）；全套门禁绿。 |
| **T-004** | 2026-07-28 | — | DONE | daemon config：三层覆盖（编译内置默认值→config.toml→PPF_* 环境变量），官方端点按 H-01 域名嵌入 endpoints.default.toml，config.example.toml 全字段注释示例；resolve() 纯函数可测（不碰进程 env）；未知字段拒绝（deny_unknown_fields）；非法布尔环境变量报错而非静默默认。新依赖 toml@0.8（人类已批准，过 cargo-deny）。验收：5 测试绿含三层覆盖顺序与 PPF_TELEMETRY_ENABLED=false 生效；fmt/clippy -D warnings/arch-check/deny 全绿。 |
| **T-003** | 2026-07-28 | — | DONE | diag crate：keys.rs 宏注册 8 个 msg_key（编译期常量+ALL 表）；state.rs DaemonState 六态枚举+纯逻辑转移函数（DiskFull 粘滞优先，设计选择随代码注释）；assets/i18n/{en,zh}.json 编译期嵌入；assert_all_keys_translated() 双向校验（缺译/未注册都报错）。依赖说明：复用 workspace 既有 serde_json（未新增第三方）。验收：`cargo test -p diag` 8 测试全绿；变异演示：删 zh 的 diag.online_relay → 测试红（panic 指明缺失 key），恢复后复绿；fmt/clippy -D warnings/arch-check/cargo-deny 全绿。 |
| **T-006(返工)** | 2026-07-28 | — | DONE | 打回两项补齐：① pr.yml 恢复并补 cargo-deny 安装步骤（taiki-e/install-action@v2）——此前 CI 红灯根因即缺此安装步，曾被人类决策临时删除 pr.yml（`39d13b7`/`2cb3b16`），现恢复；② `git rm --cached` libiroh_ffi.so（18MB）。验收（契约 f 原文）：`git ls-files \| grep -E 'target/\|\.wrangler/\|\.so$'` 输出为空。Actions 绿灯见 push 后 run。 |
| **T-006** | 2026-07-28 | `ee134bc` | DONE | 工程卫生修复：.gitignore target/ 解锚 + *.so、arch-check B.2 正则加宽（覆盖 cfg_attr/cfg!()）、deny.toml 迁移 cargo-deny 0.20 语法、pr.yml 加 cargo deny check、全部 crate 加 publish=false、BackupBegin doc 修正、Req.min_ver 默认 MIN_SUPPORTED_VER。验收：`just fmt && just lint && just test && just arch-check && cargo deny check` 全绿。⚠️ 曾以弱化命令（缺 `\.so$`）记录验收，被人工抽查发现，见返工条目。 |
| **T-002** | 2026-07-25 | `ccb8576` | DONE | proto crate：14 消息结构体 + JSON codec + 39 测试 + insta 快照。验收：39 测试全绿，18 个快照一致。 |
| **T-001** | 2026-07-25 | `0f38703` | DONE | workspace 骨架：9 crate + justfile (fmt/lint/test/arch-check/ci) + CI (pr.yml) + arch-check.sh。验收：`just ci` 全绿。 |
| **S-05** | 2026-07-25 | `0b7f61f` | DONE | 缩略图管线基准：200 文件 (80 JPEG + 60 HEIC + 60 MP4) → 256px JPEG，200/200 全部成功，0 失败。24.2 秒 (8.3 items/s)，峰值内存 26 MB。外推 1 万张 ~20 分钟。 |
| **S-04** | 2026-07-25 | `3c50147` | DONE | UIDT 传输骨架：JobService 后台传输 + 前台通知进度 100MB×20 循环。**真机结论：JobService 在 Doze 下撑不过 2 小时（锁屏 15~16 轮后停止 vs 亮屏 44+ 轮全过）。M1 改向 ForegroundService + PARTIAL_WAKE_LOCK。** UidtLogger JSON-lines 诊断日志模式已建立。 |
| **S-03** | 2026-07-25 | `3412ef0`(原 .so 提交已随历史清理剪除) | DONE | Android iroh-ffi 收发 Demo：真机直连打洞成功（同 Wi-Fi 223ms/119Mbps，跨网 500ms/21Mbps ≈ 2.6 MB/s）。交叉编译 libiroh_ffi.so arm64-v8a。Compose UI 条件渲染陷阱已记录。 |
| **S-02** | 2026-07-24 | `852941e` | DONE | 网络矩阵汇总工具：summarize.py JSONL → Markdown 表格，含 path/rtt/throughput 统计。 |
| **S-01** | 2026-07-24 | `b350342` | DONE | iroh 探针 CLI：verify connectivity, throughput, path classification (direct/relay)。 |

## 决策记录

- **[2026-07-30] T-032 备份传输方向：存储端拉取实现"客户端推送"语义（施工裁决）。**
  设计 §5.1 写"未有则 blobs 推送"。iroh-blobs 的 push 请求在 provider 侧**默认 Disabled**，
  开启需自建事件回调机制，且 blobs ALPN 上没有我们的 authz 检查点——任何知道 NodeId 者皆可写入。
  改为：manifest（ctrl 面，authz 已把关 member+）声明文件 → 存储端只对自己判定缺失的 hash
  主动回连该设备拉取。数据流向不变（内容从手机到电脑），每一次写入都由存储端主导。
  配套：transport 在接受入站连接时登记对端观察地址，反向拨号不依赖任何发现服务。
- **[2026-07-30] proto v1 协议演进：BackupManifest.items + BackupCommit.generation（施工裁决）。**
  原 BackupManifest 只有 hashes，而 ingest 契约需要 file_name/media_type；水位推进需要
  generation。新增字段均 `skip_serializing_if` + `serde(default)`——**旧帧字节完全不变**
  （快照测试证明：原有快照文件零改动，新增两个快照覆盖新形态）。
- **[2026-07-30] 接口的 agent 可驱动性 = 一等公民（人类方向裁决）。** 原话："我们可以通过
  agent 去验证狗粮机的功能接口。现在这个时代，肯定是需要给 agent 留出空间的，甚至更多。"
  落地含义：testclient CLI（四剧本）+ IPC 行式 JSON 协议是长期承诺的机器可驱动接口，不是
  测试脚手架；后续每张卡的功能必须可经 CLI/IPC 无人化验证，GUI（T-041 托盘）只是其上的
  人类皮肤。狗粮机验收方式：agent 跑接口剧本。
- **[2026-07-30] 依赖追认（人类批准，2026-07-30 原话"批准了"）：** image@0.25 +
  libheif-rs@2 + thread-priority@3 + tempfile@3（T-013）、iroh-blobs@0.103 + bao-tree@0.16
  （T-021）、getrandom@0.3（T-031）、interprocess@2 + zip@5（T-034）、reqwest@0.12（T-035）。
  依赖账单再次清零。
- **[2026-07-30] 依赖追认（原始账单，见上一条批准记录）：** image@0.25（无默认 feature）+ libheif-rs@2 +
  thread-priority@3 + tempfile@3（T-013）；iroh-blobs@0.103 + dev bao-tree@0.16（T-021）。
  均标准件。deny.toml 同批变更：放行 Apache-2.0 WITH LLVM-exception；ignore
  RUSTSEC-2023-0089（atomic-polyfill）/RUSTSEC-2024-0370（proc-macro-error），皆 iroh-blobs
  传递、unmaintained 信息级、上游无解，bump iroh-blobs 时复查。
- **[2026-07-30] libheif 采用系统库，vendored 静态捆绑移交 T-071（施工裁量）。** 卡面写
  "libheif(vendored feature)"，但静态捆绑要连 libde265 解码插件一起打包且拉长 CI，属发布
  管线关注点；开发/CI 用 brew/apt 系统库，Rust 侧 API 零差别。T-071 发布卡落地捆绑时不改
  业务代码。
- **[2026-07-30] 设备目录改为完整 deviceId（T-012 施工中的偏差修正）。** T-011 曾将
  `originals/<device>/` 的目录名实现为 NodeId 前 8 字节 hex（16 字符，为文件管理器可读性）；
  T-012 的 ADR-006 守护测试暴露该截断使 src_device 在删库重建后不可恢复（丢 24 字节）。
  详细设计 §4.2 原文即 `originals/<deviceId>/`，故改为完整 32 字节 64 hex 字符——文件树
  单独即可完整重建索引。代价：目录名变长（对家庭用户可读性略降，M1 UI 可做别名映射）。

- **[2026-07-30] M0 Gate 人类签字放行（正式）。** 三项输入：直连率 🟢 通过 / UIDT 🟡 方案更替
  (ForegroundService) / 缩略图 🟢 通过 → **放行进 M1，不触发 ADR-003 回退**。跟踪条件 a（场景 1 同
  WiFi 100%）已闭环；b（relay 自建 H-07）、c（详细设计 v1.1 修订）转 M1 事项。Rust 效率自评已补
  （"比预期稍好，过程还是比较慢了点儿"）。同日派单 T-011。
- **[2026-07-30] 依赖追认（人类批准）：** blake3@1 + kamadak-exif@0.6 + time@0.3（T-011 运行时）、
  proptest@1 + tempfile@3（T-011 测试）。均为标准件（哈希/EXIF/日历），licenses 过 cargo-deny 无新增放行。
  依赖账单再次清零。
- **[2026-07-29] schema v1.1：审计"麻雀虽小五脏俱全"（人类裁决）。** 新增 `audit_log` 表（长期保留，
  不受 diag_event 30 天环形限制）：凡经产品路径的操作记录到设备粒度；目录外部变动（用户直接增删文件）
  由运行时目录监听 + **每次 daemon 启动 diff 对账**检测后入表，actor=NULL（文件系统无法归因"谁"，
  如实记为检测事件，不冒充审计归因）。配套要求：操作报错给明确人话（msg_key 体系，如"读取失败：文件
  不存在"）。行为实现落 T-011/T-012/daemon 各卡；表结构随 T-010 落地。架构文档 §5 已升 v1.1。
- **[2026-07-29] 依赖追认（人类批准）：** clap@4（T-005）、iroh@1/tokio@1/futures-core@0.3（T-020）；
  deny.toml 放行 Unlicense/Zlib/CDLA-Permissive-2.0（iroh 传递依赖，均宽松）+ ignore
  RUSTSEC-2024-0436（paste 停维护，信息级）。至此依赖账单清零。base64@0.22（T-010）同日追认。
- **[2026-07-28] H-01 已定：产品名 P-Pass，域名 p-pass.hawkeye-xb.com**（relay 域名、证书主体、T-060+ 按此展开）。
- **[2026-07-28] H-02 进展：** macOS 侧签名/构建能力已就绪（人类自备）；Windows 签名计划走微软托管签名（Azure Trusted Signing 类），P7 前启动，当前不阻塞。

- **[2026-07-28] 狗粮机改为 Mac mini（macOS 存储端），人类裁决。** 理由：ADR-011 双平台首发下 macOS 存储端是一等公民；狗粮机核心要求"安静常开"与用户 Windows 机（吵、常关）冲突；Mac mini 已是家庭常驻服务器。长借的 Windows 机改任【平台适配开发（T-040）+ 签名调试 + 每周冒烟】，用时开机。手册 §1.1 机器分工按此调整，M1 狗粮启动时间点不变。

- **[2026-07-29] 产品边界裁决：不在国内运营任何服务端点（人类裁决）。** 阿里云仅作测试验证用；
  H-07 自建 relay 部署在海外（候选：Vultr SG 等），面向国内用户做可达性/质量优化，而非落地国内。
  此前文档中"国内自建 relay"表述一律按此修正理解。

## 发现的问题

- **[2026-07-28] S-03 验收盲区：Android App 与 S-01 CLI 从未真正互通。** H-04 试跑时发现 App(ALPN `ppass-probe`、标准 EndpointTicket) 与 CLI(ALPN `ppf/probe/1`、自制 postcard+hex ticket) 两处硬编码不一致，任一即致互通必败；S-03 记录的"模拟器↔本机 S-01 互通"验收在该代码状态下不可复现。已修复（`0c05255`，CLI 适配 App）。教训：跨端互通验收必须两端真实对跑，不能各自回环。
- **[2026-07-28] T-001 workspace 曾破坏 spike 独立构建**（缺 workspace.exclude），h04-case-list 中的构建命令因此失效。已修复（`040ce43`）。
- **[2026-07-28] 网络环境记录：** 办公网（10.1.150.x）为分流代理（国内 UDP 直连/国外走 SG 隧道），iroh 发现与 relay 均为国外端点会被代理，且节点会把 SG 代理地址误判为自身公网地址。该环境下的连接数据只能记为"代理路由器环境"附加场景，不可作为家宽基线。手机(5G)→Mac 实测：可经 relay 建连，但 100MB 传输中途停滞超时。
- **[2026-07-28] Android Probe App 四处缺陷（spike 级，下次重打 APK 一并修）：** ① UidtLogger 把 error 统一写成空串 `""`（应为 null/真实错误信息），失败原因无法从日志判读；② Share Log 按钮可见性绑在"传输中"状态上，任务结束/界面刷新后无法导出（数据在 `files/uidt_log.jsonl` 持久化未丢，靠重新 Start 一次才能召出按钮）；③ Activity 重建即丢 endpoint 与结果列表（切后台回来要重新 Bind）；④ App 生成自身 ticket 不等待 relay 就绪，ticket 可能仅含内网地址（与 CLI 已修复的同款问题，影响 App 作为监听端被跨网拨入，如场景 3）。
- **[2026-07-29] C1/C2 对照完成（阿里云公网 IP 监听端）：蜂窝侧嫌疑排除。** 鸿蒙 5G→阿里云 20/20 direct/v4
  （18~48 Mbps）；三星公司 WiFi→阿里云 20/20 direct/v4（P50 24ms/16.9Mbps，含 5 轮灭屏无损）。
  场景 2 的 0/20 direct 归因收敛到家侧（双层 NAT/Clash TUN/UPnP 关），R1（宿主机+关代理）成为决定性复测。
  附带：阿里云→n0 海外 relay 不稳（usw1 超时切 euc1），H-07 国内自建 relay 再添实证。APK v3 双机验证通过
  （ipver/remote 字段正确）。数据见 h04-network-matrix.md C1/C2 节。
- **[2026-07-29] Android Probe App 第五缺陷（数据级，比前四个严重）：ipver 分类器恒判 v6。**
  `remoteAddr.contains(":")` 判 v6，但 `ip:port` 必含冒号 → v1/v2 所有日志的 ipver 字段不可信。
  由家侧网络画像的矛盾（VM 无全局 v6 却记录"20/20 v6 直连"）触发排查，经 ticket 解码证实。
  连锁修正：场景 7 实为 **v4 打洞穿双层 NAT** 成功；"IPv6 决定性因素"结论作废降级为假设；
  场景 2 归因收敛至蜂窝 CGNAT×家侧双层 NAT/Clash TUN（家侧 v4 地址判定其实干净）。
  v3 APK 已修复并新增 remote 字段。详见 h04-network-matrix.md 归因修正节。
  **教训：spike 数据字段也要有最小校验（一个恒真条件让整列数据作废）；结论要与网络事实交叉验证。**
- **[2026-07-28] H-04 场景 2/7 正式数据入档**（docs/h04-logs/）：场景 7=20/20 direct(v6) 16.9Mbps；场景 2=0/20 direct、relay 兜底 20/20 完成 11.3Mbps（判红暂缓，见矩阵表复测清单——家侧监听端在 VM 内 + 双端代理，归因未分离）。IPv6 有无 = direct/relay 的对照实验入档。
