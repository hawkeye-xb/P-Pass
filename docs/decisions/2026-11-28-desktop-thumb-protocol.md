# 桌面端注册只读缩略图自定义协议 `ppf-thumb` 并放行 CSP `img-src`

- 状态：已采纳（产品负责人 2026-11-28 授权开工）
- 日期：2026-11-28
- 关联：#2112（桌面端缩略图灰块根治）、#1120（桌面端最小权限与 CSP 收口）

## 结论

在桌面壳注册只读自定义协议 `ppf-thumb`，直接从本机当前库 `layout.thumbs()` 目录零拷贝读取已落盘 JPEG 缩略图，并在 `apps/desktop/src-tauri/tauri.conf.json` 的 `csp.img-src` 与 `devCsp.img-src` 仅追加 `ppf-thumb: http://ppf-thumb.localhost` 放行图片渲染；仅当 `ppf-thumb` 返回 `404` 时，前端回退至带 4–6 路有界并发上限与有限次瞬时错误重试的 `thumb.get` IPC。更新公钥、updater 端点、capabilities ACL 与 Windows 服务目录加密私钥边界全部保持不变。

## 背景

1. 核对 Mac Mini `0.12.3` 诊断日志（`#2112`）：989 张资产缩略图均已生成落盘（0 条解码失败日志），真正故障是在照片墙快速滚动时，前端为每张卡片并发发起 `thumb.get` 短连接 IPC，1 秒内峰值冲出 100+ 路并发。macOS 上每条连接触发 `SecCodeCopyGuestWithAttributes` 代码签名验签打开多枚文件句柄，瞬间打爆 launchd 默认 256 `RLIMIT_NOFILE` 上限，导致 `UNIX[Too many open files]` / `Broken pipe`，而被拒格子被 `thumbLoader.js` 永久定格为灰色占位块。
2. 桌面端与 `thumbs/` 目录同处本机 SSD，网格命中已有缩略图无需经过控制面 JSON+base64 IPC 搬运。
3. 引入自定义协议 `ppf-thumb` 必须在 `apps/desktop/src-tauri/tauri.conf.json` 的 `csp.img-src` 与 `devCsp.img-src` 放行其源（否则 WebView CSP 会拦截 `<img>` 加载）；而 `tauri.conf.json` 位于 `.github/core-paths.txt` 核心名单中，须先采纳本文档并合入 `main`。

## 决定

1. **核心配置最小放行（`apps/desktop/src-tauri/tauri.conf.json`）**：
   - 在 `app.security.csp.img-src` 与 `app.security.devCsp.img-src` 末尾精确追加 `ppf-thumb: http://ppf-thumb.localhost`（覆盖 macOS WKWebView `ppf-thumb://localhost/...` 与 Windows WebView2 `http://ppf-thumb.localhost/...`）。
   - 不改动 `script-src`、`connect-src`、`default-src`、`freezePrototype`、`assetProtocol`、`capabilities/default.json` 及 `plugins.updater`。
   - 同步更新 `apps/desktop/src-tauri/src/lib.rs` 中 `webview_security_config_is_locked` 测试，断言 `csp` 与 `devCsp` 的 `img-src` 显式包含 `ppf-thumb:` 与 `http://ppf-thumb.localhost`，同时保持 `object-src 'none'`、`script-src 'self'`、`https:` 禁用、无通配 `*` 等锁定门禁。
2. **后台暴露当前库 `thumbs_dir`（`crates/daemon/src/ipc.rs`）**：
   - `status` 响应在库已加载正常服务时增加 `thumbs_dir`（对应 `layout.thumbs()` 绝对路径），切换库后随 `status` 更新；`unconfigured` / `library_missing` / `relocating` 等无可用库状态下不提供可读缩略图目录。
3. **桌面壳只读自定义协议 `ppf-thumb`（`apps/desktop/src-tauri/`）**：
   - 严格解析请求路径，仅接受 `<64位小写hex>.<256|1024>.jpg`（单段文件名、严禁 `/` / `\` / `..` / `%2e` / 其他扩展名或尺寸），从当前已加载的 `thumbs_dir` 拼出 `<thumbs_dir>/<前2位hex>/<hash>.<size>.jpg`。
   - 拒绝符号链接越界，并校验文件非空且前 2 字节为 JPEG 魔数 `FF D8`，命中返回 `200 image/jpeg` + `Cache-Control: public, max-age=31536000, immutable`。
   - 目录未就绪、文件名非法、越界、文件缺失、权限拒绝或魔数不符统一返回 `404` + `Cache-Control: no-store`（绝不缓存 404）。
4. **前端直读优先 + 4–6 路有界并发回退 + 瞬时重试**：
   - `PhotoThumb.svelte` / `thumbLoader.js` 按当前平台构造 `ppf-thumb` URL 优先直读（0 次 IPC、0 次代码签名验签）；仅当 `<img>` 触发 `onerror`（协议返回 404）时回退至 `thumbLoader.load()` 调用 `thumb.get`。
   - 在 `thumb.get` 通道施加有界并发上限（4–6 路）并对瞬时 IPC 错误做有上限退避重试（最多 2 次），确保刚入库大规模 404 回退风暴或偶发断连不会再打爆 256 FD 或永久卡灰块。
5. **Windows 服务目录权限兼容**：
   - Windows `%ProgramData%\P-Pass` ACL 继续保持服务账户与 Administrators 最小权限，不动 ACL；普通用户直接访问出现 `PermissionDenied` 时协议返回 `404 (no-store)`，前端自动无感降级走限流后的 `thumb.get`。

## 理由

- **本质保证**：将高频本地缩略图读取从控制面短连接 IPC 下沉到 WebView 原生自定义协议零拷贝直出，从根本上消除数百并发连接触发 `SecCodeCopyGuestWithAttributes` 撞爆 256 FD 的问题；同时以严格路径正则、只读作用域与 JPEG 魔数校验把攻击面死锁在 `thumbs_dir` 的已重编码缩略图上，绝不暴露原图路径或 `index.sqlite`。
- **标准对齐**：遵循 Tauri v2 自定义 URI Scheme 协议规范（WKWebView `scheme://localhost/...` 与 WebView2 `http://scheme.localhost/...`）及 HTTP 内容寻址不可变缓存与负响应禁缓存惯例。

## 后果

- **可逆缓存语义**：`Cache-Control: public, max-age=31536000, immutable` 依赖 `(hash, size)` 的内容不可变性；未来若调整缩略图压缩参数并需让旧缓存失效，需在 `ppf-thumb` URL 中加入版本前缀。
- **Windows 普通用户降级路径**：Windows 普通桌面用户若无 `%ProgramData%\P-Pass\...\thumbs` 读权限，会稳定经由 `404` 降级到 4–6 路并发的 `thumb.get`（Windows 使用命名管道，不触发 macOS 签名 FD 问题），不暴露私钥且不白屏。
- **不涉及范围**：不改变 `asset://` 视频流播放单文件按需放行策略，也不放松任何远端或脚本 CSP 指令。

## 备选

- **经 Tauri IPC 命令直接读盘返回 base64**：不采纳。虽能避开 `tauri.conf.json` 修改与句柄耗尽，但每张缩略图仍需 base64 编码放大 33% 体积并在 JS DOM 长期驻留文本内存、切页无法享受 WebView 原生二进制 `immutable` 缓存，上万张规模下滚动流畅度与内存不如自定义协议。
- **复用内置 `asset://` 协议并把整个 `thumbs_dir` 放进 `assetProtocol.scope`**：不采纳。`asset://` 服务于通用路径读取且需向前端暴露本机文件系统路径并动态放宽目录级 scope；专用 `ppf-thumb` 仅接收 `<64-hex>.<256|1024>.jpg`，前端既不知道磁盘绝对路径也无法探测库内其他文件。
