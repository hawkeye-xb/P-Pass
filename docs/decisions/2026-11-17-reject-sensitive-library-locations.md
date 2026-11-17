# 照片库位置直接拒绝敏感目录

- 状态：已采纳（产品负责人 2026-11-17，[定案](https://github.com/hawkeye-xb/P-Pass/issues/1826#issuecomment-6942699574)）
- 日期：2026-11-17
- 关联：#1826、#1828
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

服务形态下 daemon 以 `NT SERVICE\P-Pass` 运行：`home_dir()` 在主人记录落下前是 `None`，`pictures_dir()` 答的是服务账户自己的 Known Folder，都不是主人的。所以不能拿适配器（服务账户）的目录代答，也不按 `C:\Users\<名字>\Desktop` 这类路径形状猜。

修法用 Windows 标准机制，不自己造：

- 命名管道服务端已按连接 `ImpersonateNamedPipeClient` + `OpenThreadToken` 取客户端令牌；令牌权限从 `TOKEN_QUERY` 加到 `TOKEN_QUERY | TOKEN_DUPLICATE`。
- 用该令牌调 `SHGetKnownFolderPath`（`FOLDERID_PROFILE`、`FOLDERID_Pictures`，第三个参数传该用户 hToken；依据 Microsoft Learn `SHGetKnownFolderPath`：指定用户就传该用户令牌，需 `TOKEN_DUPLICATE`、该用户 hive 已挂载——正在连接的交互桌面用户总是已挂载）。
- 结果随 `PeerUser` 携带（SID + 家目录 + 「图片」），由常驻与未配置两条会话路径显式传到 `config.set_library` 与 `library.relocate`。不设全局「当前用户」，不把这些路径写日志。
- 有连接方（`peer`）时只用它的目录事实；连接方存在但目录事实缺失 ⇒ 拒绝本次设置并回 `ui.err_library_user_dirs`，**不**退回服务账户、不按形状放行。没有连接方（macOS 签名 socket、令牌模式）才问平台适配器。

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
