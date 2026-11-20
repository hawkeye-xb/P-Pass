# 照片库位置直接拒绝敏感目录

- 状态：已采纳（产品负责人 2026-11-17，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1826#issuecomment-6942699574)；2026-11-20 修订 Windows 服务形态目录事实传递方案 A，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1918#issuecomment-7029525887)）
- 日期：2026-11-17（2026-11-20 修订）
- 关联：#1826、#1828、#1918
- 代码基线：`92d02e9b`

## 结论

选择照片库位置时，系统、用户敏感、同步/云、应用自身目录和可移动卷根一律**直接拒绝**，不做「强提示后允许」。校验必须在创建库目录、写 config 或开始搬迁之前完成。

## 判定口径

按解析符号链接后的真实路径逐段规范化（`..` 按真实路径回退，`.` 忽略；解析不出则拒绝）：

- 系统根与系统目录：`/`、`/System`、`/Library`、`/Applications`、`/Users`、`/private`、`/tmp`、`/var`、`/Volumes` 本身；Windows 的 `Windows`、`Program Files`、`Program Files (x86)`、`ProgramData`、`$Recycle.Bin`、`System Volume Information` 及其内部。
- 用户敏感目录：家目录本身，以及 `Desktop`、`Documents`、`Downloads`、`Library`、`Pictures`、`Movies`、`Music`、`Videos` 及其内部。
- 同步/云目录：iCloud Drive、Mobile Documents、CloudStorage、Dropbox、OneDrive（含「OneDrive - 组织」）、Google Drive，按整条真实路径判断，不限制在家目录内。
- 应用自身：`~/Library/Application Support/P-Pass` 与安装目录。
- 可移动卷根：`/Volumes/<卷>`、`/mnt/<卷>`、`/media/<卷>`、`/media/<用户>/<卷>`、`C:\`；只允许卷内专用子目录。

`/private/tmp`、`/private/var` 精确拒绝（macOS 上 `/tmp`、`/var` 的真实路径），它们的子目录照常放行（`/private/var/folders` 是系统临时目录）。

**默认库位置例外**：`<真实「图片」目录>/P-Pass Library` 与旧名 `<真实「图片」目录>/P-Pass 家庭照片库` 放行；「图片」本身（含被重定向到 `D:\PhotoArchive` 之类）和其他子目录仍拒绝。否则首启默认位置和旧默认位置都会被自己的校验拒绝。默认库位置按「真实图片目录 + 默认名」**词法拼接**，不对默认库本身 `canonicalize`——默认库若链到桌面，把它解析成桌面就会把桌面加进白名单。

## Windows 服务形态的目录事实

服务形态下 daemon 以 `NT SERVICE\P-Pass` 运行：`home_dir()` 在主人记录落下前是 `None`，`pictures_dir()` 答的是服务账户自己的 Known Folder，都不是主人的。同时，服务账户刻意禁止 `SeImpersonatePrivilege`（`crates/platform/src/service_privileges.rs`），且客户端连接命名管道刻意使用 `SECURITY_IDENTIFICATION`（`crates/platform/src/windows_pipe.rs`），因此服务端无法用标识级令牌代调 `SHGetKnownFolderPath`。所以不能拿适配器（服务账户）的目录代答，也不按 `C:\Users\<名字>\Desktop` 这类路径形状猜，也**不**给服务加高危特权、**不**放宽管道 `SECURITY_IDENTIFICATION` 边界。

修法采用方案 A（产品负责人 2026-11-20 拍板，#1918）：

- **客户端（本机主人桌面进程）取事实**：桌面进程跑在主人的交互会话里，在发起 `config.set_library` 与 `library.relocate`（含预检与落计划）时，直接调用 Windows 标准 API `SHGetKnownFolderPath`（`platform::UserDirFacts::for_current_user()`）获取主人的家目录与各用户标准目录真实位置，随请求参数 `user_dirs` 传给 daemon。
- **服务端管道仅做 SID 鉴权**：命名管道服务端 `ImpersonateNamedPipeClient` + `OpenThreadToken(TOKEN_QUERY)` 只取客户端 SID（不请求 `TOKEN_IMPERSONATE` / `TOKEN_DUPLICATE`，不再用标识级令牌徒劳调 `SHGetKnownFolderPath`）。同用户直跑/计划任务形态（服务端 SID == 客户端 SID）直接用服务端当前用户事实（不接受客户端覆盖）；跨用户服务形态（`NT SERVICE\P-Pass` ≠ 客户端 SID）服务端侧 `PeerUser.dirs` 初始为空，绝不拿服务账户目录代答。
- **服务端校验后执行敏感目录判定**：收到已通过管道 SID 鉴权的 `config.set_library` / `library.relocate` 请求时，若服务端侧目录事实未就绪，必须解析并校验请求里的 `user_dirs`（家目录 + 除 macOS `library` 外的 6 项标准目录均非空、为本机盘符绝对路径且不含 `..`，拒绝 UNC 网络路径与 `\\.\` / `\\?\` 非盘符设备命名空间以防服务账户外连或设备访问，可选 `library` 若存在亦同）；目标照片库路径本身（`library` / `target`）在 `check_library_path` 进入任何 `canonicalize()` 之前同样共用该判据拒绝 UNC 与设备命名空间。校验通过后绑定到 `PeerUser` 执行既有敏感目录拒绝规则；缺失（如老版本客户端）、格式非法、残缺或非法路径一律拒绝并回 `ui.err_library_user_dirs`，**不**退回服务账户、不按形状放行。不设全局「当前用户」，不把这些路径写日志。
- 没有连接方（macOS 签名 socket、令牌模式）仍按平台当前用户事实判，不受影响。

## 搬迁计划的提交

新位置在 `relocate::plan/check` 时按连接方（主人）的事实校验过；重启后 daemon 没有连接方，拿服务账户或适配器的目录事实**再判一次**会在收尾失败并把源和目标拆开。所以两条入口显式分开：

- 用户在选新位置（`config.set_library`、`library.relocate` 的预检与落计划）：必须校验。
- 提交已持久化的搬迁计划（`LibraryLocation::commit_relocated`，只由搬迁收尾调用）：不再当作新的位置选择，只提交计划。

旧版本留下的中断计划按「不纠正存量配置」原定口径完成或回滚，不借本卡做迁移。

## 调用点

- `LibraryLocation::set` / `config::init_config` / `config::set_library`：写 config、建 `.ppf` 之前校验（选择档）。
- `relocate::check` / `plan`：在 `create_dir_all` 和复制之前校验，不能先建进敏感目录再回滚。
- 搬迁收尾：`LibraryLocation::commit_relocated`（计划档，不重新校验）。

## 不做什么

- 不纠正已经存在于敏感目录的存量配置，只拦本次选择。
- 不改库数据格式，不写迁移。
- 不靠平台 `#[cfg]` 写在 daemon；平台差异（Known Folder 取值）留在 `crates/platform`，daemon 只消费 `PeerUser` 的事实，保持 architecture 门禁。

## 验收

- 上述每一类目录被拒绝，普通独立目录正常保存。
- 默认库位置和旧默认库位置放行。
- 符号链接解析后命中敏感目录同样拒绝。
- Windows 盘符路径与 canonicalize 后的路径都按系统目录拒绝。
- Windows 服务形态：主人桌面 / 文稿 / 下载 / 家目录本身拒绝，默认库位置放行（用 peer 事实的跨平台构造测试）。
- 「图片」被重定向时根与普通子目录拒绝、两个默认名放行；默认库链到桌面拒绝。
- 搬迁预检用 peer 事实；收尾 commit 不重新做选择校验。
- 反证：去掉任一类校验、去掉搬迁预检、或把提交计划改成重新校验，对应用例变红。
