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

**默认库位置例外**：`~/Pictures/P-Pass Library` 与旧名 `~/Pictures/P-Pass 家庭照片库` 放行；`~/Pictures` 本身和其他子目录仍拒绝。否则首启默认位置和旧默认位置都会被自己的校验拒绝。

## 调用点

- `LibraryLocation::set` / `config::init_config`：写 config、建 `.ppf` 之前校验。
- `relocate::check` / `plan`：在 `create_dir_all` 和复制之前校验，不能先建进敏感目录再回滚。

## 不做什么

- 不纠正已经存在于敏感目录的存量配置，只拦本次选择。
- 不改库数据格式，不写迁移。
- 不靠平台 `#[cfg]` 写在 daemon；平台相关形状判断放在可跨平台测试的纯函数里，保持 architecture 门禁。

## 验收

- 上述每一类目录被拒绝，普通独立目录正常保存。
- 默认库位置和旧默认库位置放行。
- 符号链接解析后命中敏感目录同样拒绝。
- Windows 盘符路径与 canonicalize 后的路径都按系统目录拒绝。
- 反证：去掉任一类校验或去掉搬迁预检，对应用例变红。
