## T-042b — desktop wizard/badge regressions / 桌面向导与徽章回归

按 docs/m3-review-fixes.md 施工。

### 修复项（卡面七条全做）
1. **徽章渲染原始占位符**：`t(STATE_KEYS[...])` 不传 vars → INDEXING/STORAGE_OFFLINE 显示字面 `{progress}`/`{last_seen}`。新增**桌面视角无占位符变体**（status 载荷不带这两个值，传了也渲染不出）
2. **字典视角错误**：手机视角文案（"存储电脑离线了"、"等待存储电脑上确认…"）显示在存储电脑本身上自相矛盾——新增 `diag.desktop.*` 变体 key（storage_offline/pairing/indexing/disk_full），桌面壳 STATE_KEYS 映射到变体；msg_key 共享、字典按 surface 分变体
3. **oneshot 降级用户回弹 wizard**：autostart 注册失败（fallback spawn）的用户 `installed=false`，daemon 一停就回 wizard step1，重选文件夹会重指 config（孤儿库风险）——`wizard_state` 新增 `configured_library_dir`（读 config.toml data_dir），Wizard 预填已有配置，回弹不会重定向
4. **token 发现 macOS-only**：`ipc.rs` 硬编码 `~/Library/Application Support/P-Pass/config.toml` + HOME——改用 `platform::adapter().data_dir()`（Windows 拿 %APPDATA%\P-Pass），config 解析抽为共享 `read_config_data_dir`
5. **测试改写真实 config.toml**：原测试直接写开发者真实 `~/Library/.../config.toml` 且 panic 跳过恢复——改为 temp dir（`token_candidates_from(data_dir)` 注入）；**src-tauri 测试接进 pr.yml**（此前从不跑）
6. **同屏混合语言**：徽章 locale-aware 但"后台服务未运行"和 else 分支硬编码 zh——全部 UI 文案收编字典（新增 `ui.*` 前缀 key 48 个，en/zh 齐全），整屏单语
7. **StringsSymmetryTest 正则解析**：`name="...">([^<]*)</string>` 静默跳过带属性/多行条目——改真实 DOM 解析器（javax.xml），并新增回归测试证明带属性 + CDATA 条目都被捕获

### 验收
- ✅ `cargo test -p diag` 8/8（新增 48 key 全部注册 + 双语齐全）
- ✅ src-tauri `cargo test --lib` 2/2（temp-dir 版）
- ✅ `vite build` 绿
- ✅ Android `StringsSymmetryTest` 绿（真实 XML 解析）
- ⏳ 三态走查（indexing/offline/pairing 无占位符、无混语言、视角正确）需用户真机确认

### 注意
- 只动 `apps/desktop/`、`assets/i18n/`、`crates/diag/`、`apps/android/.../StringsSymmetryTest.kt`、pr.yml（src-tauri 测试 step）、ROADMAP；未触碰 `infra/selfhost/`、`infra/relay/`
