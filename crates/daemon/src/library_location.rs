//! #1115：照片库位置——安全相关配置，只认本应用签名程序写入的值。
//!
//! 库位置决定 daemon 拿什么目录、用真身份对外服务。config.toml 同一用户谁都能改，所以：
//! - **正本**：有平台安全存储时（macOS 钥匙串，只有带访问组授权的签名 daemon 读写得了）
//!   正本在那里，config.toml 里的 `data_dir` 只给人看、daemon 不认；没有安全存储的平台
//!   （Windows / Linux）正本仍是 config.toml。
//! - **唯一写者**：[`LibraryLocation::set`]，只经 IPC 方法 `config.set_library` 调到，且
//!   只对验过签名的窗口程序开放（`ipc.rs`）。以前的 CLI 子命令 `config init` /
//!   `config set-library` 已删除：签名的 daemon 谁都能带参数运行，CLI 写入口等于谁都能改。
//! - **未配置**：正本里还没有库位置 ⇒ daemon 进入「未配置」状态（只答 `status` 与
//!   `config.set_library`，不开库、不起传输），由窗口程序的首启向导完成配置。没有安全存储的
//!   平台上「正本里没有」= 平台目录里没有 config.toml（两个平台同一口径：首启一次性拉起的
//!   daemon 不会先在平台目录开库、占端口）。

use std::path::{Component, Path, PathBuf};

use crate::config::{self, Config, CONFIG_FILE_NAME};

/// 库标记目录名。库标记在 = 这里确实是那个照片库（Syncthing 的 `.stfolder` 同理）。
pub const LIBRARY_MARKER: &str = ".ppf";

/// #1253：库此刻在不在——只认库标记，光有同名目录不算（外置盘没挂时原位置可能冒出一个空目录）。
/// 启动判定与删除索引前的护栏用同一个判据。
pub fn library_marker_present(root: &std::path::Path) -> bool {
    root.join(LIBRARY_MARKER).is_dir()
}

/// t2-4：启动时库目录私有核对的日志（每种结果一行；成功路径也留痕）。
pub fn log_library_privacy(dir: &Path, privacy: platform::Result<platform::LibraryPrivacy>) {
    use platform::LibraryPrivacy::*;
    match privacy {
        Ok(NotApplicable) => {}
        Ok(Private) => tracing::info!("t2-4: 照片库目录权限核对通过（只有主人能访问）"),
        Ok(NotPrivate { detail }) => {
            tracing::warn!("t2-4: 照片库目录不是私有的（{detail}）：{}", dir.display())
        }
        Ok(NoAcl { file_system }) => {
            tracing::info!("t2-4: 照片库所在的卷（{file_system}）没有权限可设，不核对")
        }
        Err(e) => tracing::warn!("t2-4: 照片库目录权限核对失败：{e}"),
    }
}

// ── #1826：选择照片库位置时直接拒绝敏感目录 ──────────────────────────────
//
// 产品定案：命中即拒绝（不做「强提示后允许」）。判据是**解析符号链接后的真实路径**：
// 选的是 `~/Desktop/photos` 还是链到它的 `~/photos` 都一样挡。判据本身是纯函数
// （[`sensitive_kind`]），文件系统事实由调用点提供，测试能直接喂假的家目录。

/// #1826：敏感目录的分类。分类只用于日志/测试分辨命中的是哪一类，界面文案同一个。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitiveKind {
    /// 系统根与系统目录：`/`、`/System`、`/Library`、`/Applications`、`/Users`、
    /// `/private`、`/tmp`、`/var`、Windows 的 `Windows` / `Program Files` / `ProgramData`。
    SystemDir,
    /// 可移动卷（含外置盘）的根目录：只允许卷内的专用子目录。
    VolumeRoot,
    /// 家目录本身（家目录里的普通子目录不受影响，`~/personal/PPASS_STORAGE` 照常放行）。
    HomeDir,
    /// 用户的标准目录（桌面、文稿、下载、图片、影片、音乐、Library）及其内部。
    UserDir,
    /// 同步/云盘目录（iCloud Drive、Dropbox、OneDrive、Google Drive 等）及其内部。
    CloudDir,
    /// 应用自身：安装目录、本应用的数据目录及其内部。
    AppDir,
}

/// #1826：新建库的默认目录名（B10 #1043：固定英文名，不随界面语言变；桌面壳的
/// `DEFAULT_LIBRARY_DIR_NAME` 是同一个名字）。
pub const DEFAULT_LIBRARY_DIR_NAME: &str = "P-Pass Library";

/// #1826：改名前（B10 #1043 之前）的默认目录名——存量机器上的库还可能是它，照常放行。
pub const LEGACY_DEFAULT_LIBRARY_DIR_NAME: &str = "P-Pass 家庭照片库";

/// #1826：判定所需的本机事实（都按真实路径给）。
#[derive(Debug, Clone, Default)]
pub struct LocationEnvironment {
    /// 家目录（主人）；读不到就是 `None`（不做家目录相关的判定）。
    pub home: Option<PathBuf>,
    /// 用户标准目录的**真实位置**（桌面 / 文稿 / 下载 / 图片 / 影片 / 音乐，macOS 的
    /// `~/Library`）。系统允许把它们重定向到家目录外（`D:\PhotoArchive`、iCloud 接管、
    /// symlink 出去），按名字在家目录下判不到——必须按真实位置逐个判。
    pub user_dirs: Vec<PathBuf>,
    /// 应用自身的目录：数据目录（平台目录）、安装目录。
    pub app_dirs: Vec<PathBuf>,
    /// 应用自己建的默认库位置（真实「图片」目录下的专用子目录，新旧两个默认名）。
    /// 这些是**唯一**允许落在用户「图片」目录里的位置——别的子目录照常拒绝。
    pub default_libraries: Vec<PathBuf>,
}

impl LocationEnvironment {
    /// 用户目录事实到判定环境的映射：每个目录取真实路径，应用目录取本进程的。
    ///
    /// `peer` 是这次连接已核验的连接方（Windows 管道服务端取得到）：**有它就只用它解析
    /// 出来的主人目录事实**——服务形态下服务账户自己的目录不是主人的，拿它代答会把
    /// 主人的桌面当成普通目录放行。没有连接方（签名 socket、令牌模式）才问平台。
    pub fn platform(platform_dir: &Path, peer: Option<&platform::PeerUser>) -> Self {
        let facts = match peer {
            Some(peer) => peer.dirs().clone(),
            None => platform::UserDirFacts::for_current_user(),
        };
        let mut env = Self::from_facts(facts);
        env.add_app_dirs(platform_dir);
        env
    }

    /// [`LocationEnvironment::platform`] 的用户目录部分（测试喂合成事实用）。
    pub fn from_facts(facts: platform::UserDirFacts) -> Self {
        let default_libraries = facts
            .pictures
            .as_ref()
            .map(|p| real_path(p))
            .map(|pictures| {
                // 默认库位置 = 「图片」的真实路径 + 默认名，**词法拼接**、不 canonicalize
                // 默认库本身：默认库要是链到了桌面，把它解析成桌面就会把桌面当成白名单，
                // 正中下怀。
                [DEFAULT_LIBRARY_DIR_NAME, LEGACY_DEFAULT_LIBRARY_DIR_NAME]
                    .iter()
                    .map(|name| pictures.join(name))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            home: facts.home.as_ref().map(|h| real_path(h)),
            user_dirs: facts.standard_dirs().map(|d| real_path(d)).collect(),
            app_dirs: vec![],
            default_libraries,
        }
    }

    fn add_app_dirs(&mut self, platform_dir: &Path) {
        let mut app_dirs = vec![real_path(platform_dir)];
        if let Ok(exe) = std::env::current_exe() {
            let exe = real_path(&exe);
            if let Some(parent) = exe.parent() {
                app_dirs.push(parent.to_path_buf());
            }
            // 打包产物：`.app` bundle 本身也算安装目录（开发版在 `~/Applications` 里，
            // 选 bundle 内 `Resources` 之类不能被当成普通目录）。
            for ancestor in exe.ancestors().skip(1).take(6) {
                let is_bundle = ancestor
                    .file_name()
                    .is_some_and(|n| n.to_string_lossy().to_lowercase().ends_with(".app"));
                if is_bundle {
                    app_dirs.push(ancestor.to_path_buf());
                }
            }
        }
        self.app_dirs = app_dirs;
    }
}

/// #1826：家目录下的用户标准目录（小写比较；Windows 的 `Videos` 对应 macOS 的 `Movies`）。
const USER_DIRS: &[&str] = &[
    "desktop",
    "documents",
    "downloads",
    "library",
    "pictures",
    "movies",
    "music",
    "videos",
];

/// #1826：同步/云盘的目录名（小写比较）。`Library/Mobile Documents`（iCloud Drive）与
/// `Library/CloudStorage`（文件提供程序接入的 Dropbox/OneDrive/Google Drive）也在这里——
/// 它们本来就在 `~/Library` 之内，单列出来是为了分类说得清。
///
/// 只收名字本身就指明是同步盘的（`box` 这种一个常见单词的名字不收：家目录里叫 `box`
/// 的普通文件夹比 Box 同步盘常见，误伤正常目录更糟；Box 走 `CloudStorage` 一样挡得住）。
const CLOUD_DIRS: &[&str] = &[
    "dropbox",
    "onedrive",
    "google drive",
    "googledrive",
    "icloud drive",
    "iclouddrive",
    "mobile documents",
    "cloudstorage",
    "pcloud drive",
];

/// #1826：把路径逐段解析成真实路径：每推进一步就把已存在的前缀 `canonicalize`（符号
/// 链接在那里就地展开），`..` 按**真实路径**回退而不是字面拼接，`.` 略过。
///
/// 为什么不能只在最后 `canonicalize` 一次、失败就原样放行：判据跑在「建库目录之前」，
/// 目标往往还不存在；而 `~/Desktop/..` 这种写法会把敏感目录藏起来。逐段解析让不存在的
/// 尾巴照常保留（`~/personal/PPASS_STORAGE` 也还不存在），同时保证 `..` 带不偏判定。
///
/// 解析不了（`..` 退到根之上、相对路径退到空）⇒ `None`——调用方必须拒绝，不能按字面放行。
fn resolve_components(p: &Path) -> Option<PathBuf> {
    let mut out = PathBuf::new();
    for comp in p.components() {
        match comp {
            Component::Prefix(prefix) => out.push(prefix.as_os_str()),
            Component::RootDir => out.push(std::path::MAIN_SEPARATOR.to_string()),
            Component::CurDir => {}
            Component::ParentDir => {
                if !out.pop() {
                    return None;
                }
            }
            Component::Normal(name) => {
                out.push(name);
                if let Ok(real) = out.canonicalize() {
                    out = real;
                }
            }
        }
    }
    (!out.as_os_str().is_empty()).then_some(out)
}

/// #1826：真实路径的宽松版本（家目录、应用目录这类系统给的事实用它；它们要么存在、
/// 要么解析得了，解析不了就按字面算）。
pub fn real_path(p: &Path) -> PathBuf {
    resolve_components(p).unwrap_or_else(|| p.to_path_buf())
}

/// #1826：组件比较的归一（大小写不敏感——macOS / Windows 的文件系统默认如此；Linux 上
/// 变得更严格，不会放行不该放的）。
fn norm_component(c: Component<'_>) -> Option<String> {
    match c {
        Component::Normal(s) => Some(s.to_string_lossy().to_lowercase()),
        Component::Prefix(p) => Some(p.as_os_str().to_string_lossy().to_lowercase()),
        _ => None,
    }
}

/// #1826：`real` 等于 `base` 或在它内部 ⇒ 返回相对 `base` 的分量（小写）；否则 `None`。
fn under(real: &Path, base: &Path) -> Option<Vec<String>> {
    let mut r = real.components();
    for b in base.components() {
        match r.next() {
            Some(rc) if norm_component(rc) == norm_component(b) => {}
            _ => return None,
        }
    }
    Some(
        r.map(|c| c.as_os_str().to_string_lossy().to_lowercase())
            .collect(),
    )
}

/// #1826：路径的**名字**分量（小写）：跳过根与 `Component::Prefix`（Windows 的盘符
/// `C:`）。系统目录、卷根、云盘都按它判——盘符前缀本身不是目录名，混在里面会让
/// `C:\Windows`、`C:\Program Files` 落空。
fn names(p: &Path) -> Vec<String> {
    p.components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect()
}

/// #1826：可移动卷的根目录。
///
/// - Windows：盘符根 `C:\`（只允许盘内的专用子目录）。
/// - macOS：`/Volumes/<卷>`。Linux：`/mnt/<卷>`、`/media/<卷>`、`/media/<用户>/<卷>`。
///
/// 不按 `cfg` 分平台判：判据是路径的形状，平台分叉归 `crates/platform`，这里只看分量。
fn is_volume_root(real: &Path) -> bool {
    volume_root_shape(
        real.has_root(),
        real.parent().is_none(),
        real.components().any(|c| matches!(c, Component::Prefix(_))),
        &names(real),
    )
}

/// [`is_volume_root`] 的形状判据（只吃路径分解出的事实，两种平台的形状都能在任意机器上测）。
fn volume_root_shape(rooted: bool, parentless: bool, has_prefix: bool, comps: &[String]) -> bool {
    if !rooted {
        return false;
    }
    // 有根、没有父目录、而分量只剩盘符前缀（`C:\`）⇒ Windows 盘符根。
    // UNIX 的 `/` 没有前缀也没有分量，由 [`is_system_dir`] 归类。
    if parentless && (has_prefix || !comps.is_empty()) {
        return true;
    }
    match comps {
        [a, _] => a == "volumes" || a == "mnt" || a == "media",
        [a, _, _] => a == "media",
        _ => false,
    }
}

/// #1826：系统根与系统目录。列表里的目录**本身**一律拒绝；`/System`、`/Library`、
/// `/Applications` 与 Windows 的 `Windows`、`Program Files`、`ProgramData` 连内部一起
/// 拒绝（系统装软件的归档处，里面没有用户该放开的东西）。
///
/// `/tmp`、`/var`、`/private` 只拒绝目录本身：它们的内部含系统临时目录（macOS 的
/// `$TMPDIR` 在 `/private/var/folders`），连内部一起拒绝会挡掉正常可选的位置；这些
/// 位置里用户存得进东西的地方（`/private/tmp` 等）本来就活不过重启，且写入与卷检查
/// 兜得住。
fn is_system_dir(real: &Path) -> bool {
    if !real.has_root() {
        return false;
    }
    // [`names`] 已跳过 `Component::Prefix`：`C:\Windows` 的顶层名是 `windows`。
    let c = names(real);
    const EXACT: &[&str] = &[
        "system",
        "library",
        "applications",
        "users",
        "private",
        "tmp",
        "var",
        "volumes",
        "windows",
        "program files",
        "program files (x86)",
        "programdata",
        "$recycle.bin",
        "system volume information",
    ];
    const TREES: &[&str] = &[
        "system",
        "library",
        "applications",
        "windows",
        "program files",
        "program files (x86)",
        "programdata",
        "$recycle.bin",
        "system volume information",
    ];
    // macOS 的 `/tmp`、`/var` 是 `/private/...` 的符号链接：按真实路径解出来之后要精确
    // 命中这两个（它们自己的子目录照常放行——`/private/var/folders` 是系统临时目录）。
    if c.as_slice() == ["private", "tmp"] || c.as_slice() == ["private", "var"] {
        return true;
    }
    match c.first() {
        // 没有名字分量 = 文件系统根（`/`；`C:\` 已由 [`is_volume_root`] 先归类）。
        None => true,
        Some(top) => {
            (c.len() == 1 && EXACT.contains(&top.as_str())) || TREES.contains(&top.as_str())
        }
    }
}

/// #1826：同步/云盘目录名（允许带后缀，如 Windows 的 `OneDrive - Contoso`）。
fn is_cloud_dir(name: &str) -> bool {
    CLOUD_DIRS
        .iter()
        .any(|n| name == *n || name.starts_with(&format!("{n} ")))
}

/// #1826：真实路径落在哪一类敏感目录里；普通目录返回 `None`。
///
/// 顺序：卷根 / 系统目录 → 两个精确的默认库例外 → 应用自身 → 同步盘 → 用户标准目录的
/// 真实位置 → 家目录与用户标准目录的名字判据。
pub fn sensitive_kind(real: &Path, env: &LocationEnvironment) -> Option<SensitiveKind> {
    if is_volume_root(real) {
        return Some(SensitiveKind::VolumeRoot);
    }
    if is_system_dir(real) {
        return Some(SensitiveKind::SystemDir);
    }
    let n = names(real);
    // 应用自己在「图片」下建的默认库位置：唯一的例外（产品定案：其他子目录、以及
    // 「图片」本身都拒绝）。排在同步盘与用户目录之前——Windows 的「图片」被系统重定向
    // 到 OneDrive 时，默认库位置仍然必须能用。默认库本身**不** canonicalize（见
    // [`LocationEnvironment::from_facts`]），所以默认库链到桌面时这里不会把桌面放行。
    if env.default_libraries.iter().any(|d| d == real) {
        return None;
    }
    // 应用自身：数据目录在 `~/Library/Application Support` 里，该报「应用自身」。
    if env.app_dirs.iter().any(|d| under(real, d).is_some()) {
        return Some(SensitiveKind::AppDir);
    }
    // 同步/云盘按整条真实路径判，且排在家目录判断之前：`D:\OneDrive`、
    // `/Volumes/Backup/Dropbox/…` 在家目录之外也照样拦。
    if n.iter().any(|c| is_cloud_dir(c)) {
        return Some(SensitiveKind::CloudDir);
    }
    // 用户标准目录的**真实位置**：桌面 / 文稿 / 下载 / 图片 / 影片 / 音乐（macOS 的
    // `~/Library`）可能被系统重定向或 symlink 到家目录之外（`D:\PhotoArchive`、
    // `/Volumes/Data/PersonalDocs`），只按家目录下的名字判不到它们——逐个真实位置判，
    // 目录本身与子树一起拒（默认库例外在上面已放行）。
    if env.user_dirs.iter().any(|d| under(real, d).is_some()) {
        return Some(SensitiveKind::UserDir);
    }
    let home = env.home.as_deref()?;
    let rel = under(real, home)?;
    if rel.is_empty() {
        return Some(SensitiveKind::HomeDir);
    }
    if USER_DIRS.contains(&rel[0].as_str()) {
        return Some(SensitiveKind::UserDir);
    }
    None
}

/// #1826：选择照片库位置的第一道校验——按真实路径判敏感目录，命中直接拒绝。
/// 在**创建库目录、写 config、搬迁之前**调用（[`config::init_config`] /
/// [`config::set_library`] / `relocate::check`），所以命中时磁盘上什么都不留。
///
/// 路径解析不出真实路径（`..` 退到根之上之类）也拒绝，不按字面放行。
pub fn check_library_path(
    target: &Path,
    platform_dir: &Path,
    peer: Option<&platform::PeerUser>,
) -> Result<(), String> {
    // 有连接方却取不全它的用户目录事实（家目录与各标准目录）：服务形态下不能拿服务
    // 账户的目录代答（那会把主人的桌面当普通目录放行），当场拒绝并说清楚。
    if let Some(peer) = peer {
        if !peer.dirs().selection_ready() {
            tracing::warn!("#1826: 连接方是主人，但取不齐主人的家目录与用户标准目录，拒绝本次设置");
            return Err(config::ui_err("ui.err_library_user_dirs", &[]));
        }
    }
    let Some(real) = resolve_components(target) else {
        tracing::info!("#1826: 选择的位置解析不出真实路径：{}", target.display());
        return Err(config::ui_err(
            "ui.err_library_target_missing",
            &[("dir", &target.display())],
        ));
    };
    let env = LocationEnvironment::platform(platform_dir, peer);
    match sensitive_kind(&real, &env) {
        Some(kind) => {
            tracing::info!(
                "#1826: 拒绝把照片库放在敏感目录（{kind:?}）：{}（真实路径 {}）",
                target.display(),
                real.display()
            );
            Err(config::ui_err(
                "ui.err_library_sensitive",
                &[("dir", &target.display())],
            ))
        }
        None => Ok(()),
    }
}

/// [`check_library_path`] 的字符串入口（config.toml 里的路径是字符串）。
pub fn check_library_location(
    target: &str,
    platform_dir: &Path,
    peer: Option<&platform::PeerUser>,
) -> Result<(), String> {
    check_library_path(Path::new(target), platform_dir, peer)
}

/// 常驻 daemon 这次启动的库。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ResidentLibrary {
    /// 已配置：用这个目录。`configured` = 来自显式配置（不存在就拒绝启动，DESK-46）。
    At { dir: PathBuf, configured: bool },
    /// 正本里还没有库位置。
    Unconfigured,
}

pub struct LibraryLocation {
    store: Option<Box<dyn platform::SecretBlobStore>>,
    platform_dir: PathBuf,
}

impl LibraryLocation {
    /// 本平台的库位置（正本由平台决定）。
    pub fn for_platform() -> Self {
        use platform::PlatformAdapter as _;
        let adapter = platform::adapter();
        Self {
            store: adapter.library_store(),
            platform_dir: adapter.data_dir(),
        }
    }

    /// 测试用：指定正本与平台目录。
    pub fn with(store: Option<Box<dyn platform::SecretBlobStore>>, platform_dir: PathBuf) -> Self {
        Self {
            store,
            platform_dir,
        }
    }

    pub fn platform_dir(&self) -> &Path {
        &self.platform_dir
    }

    /// 常驻 daemon 的库。有安全存储时只看正本（config.toml 的 `data_dir` 不作数）；读不出来
    /// ⇒ `Err`，调用方拒绝启动（不回退到 config.toml）。没有安全存储时 config.toml 就是正本：
    /// 文件不存在 ⇒ 未配置；存在但没写 `data_dir` ⇒ 平台目录（老配置的语义）。
    pub fn resident_library(&self, config: &Config) -> Result<ResidentLibrary, String> {
        match &self.store {
            Some(store) => match store.read().map_err(|e| e.to_string())? {
                None => Ok(ResidentLibrary::Unconfigured),
                Some(bytes) => {
                    let dir = String::from_utf8(bytes)
                        .ok()
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty())
                        .ok_or_else(|| format!("{} 里的库位置读不懂", store.location()))?;
                    if config::configured_library_dir(&self.platform_dir).as_deref()
                        != Some(dir.as_str())
                    {
                        tracing::warn!(
                            "#1115: config.toml 的 data_dir 与正本不一致——以正本为准（{dir}）"
                        );
                    }
                    Ok(ResidentLibrary::At {
                        dir: PathBuf::from(dir),
                        configured: true,
                    })
                }
            },
            None => Ok(match &config.data_dir {
                Some(dir) => ResidentLibrary::At {
                    dir: dir.clone(),
                    configured: true,
                },
                None if !self.platform_dir.join(CONFIG_FILE_NAME).exists() => {
                    ResidentLibrary::Unconfigured
                }
                None => ResidentLibrary::At {
                    dir: self.platform_dir.clone(),
                    configured: false,
                },
            }),
        }
    }

    /// 是否还没配置过（决定这次写入是「首启」还是「改库」）。
    fn unconfigured(&self) -> Result<bool, String> {
        let cfg = self.platform_dir.join(CONFIG_FILE_NAME);
        match &self.store {
            Some(store) => Ok(store.read().map_err(|e| e.to_string())?.is_none() || !cfg.exists()),
            None => Ok(!cfg.exists()),
        }
    }

    /// 唯一写者。首启（未配置）= 建库目录、写首启模板；改库 = 校验（存在、可写、不嵌套）后
    /// 只改 `data_dir`。然后写正本。返回 config.toml 路径。重启后台服务后生效。
    /// 用户在选新位置：按敏感目录拒绝（`peer` = 本次连接已核验的主人目录事实）。
    pub fn set(&self, library: &str, peer: Option<&platform::PeerUser>) -> Result<PathBuf, String> {
        self.write(library, config::LocationCheck::Selection { peer })
    }

    /// #1826：提交**已经预检过**的搬迁计划（`relocate::plan` 时按 peer 校验过，重启后
    /// 没有连接方）。这不是一次新的位置选择，不再拿服务账户的目录事实重判一遍——重判会
    /// 在搬迁收尾时失败，把源和目标拆成两半。
    pub fn commit_relocated(&self, library: &str) -> Result<PathBuf, String> {
        self.write(library, config::LocationCheck::FromPlan)
    }

    fn write(&self, library: &str, check: config::LocationCheck<'_>) -> Result<PathBuf, String> {
        let library = config::normalize_separators(library.trim());
        let cfg = if self.unconfigured()? {
            config::init_config_with(&self.platform_dir, &library, check)?
        } else {
            config::set_library_with(&self.platform_dir, &library, check)?
        };
        // #1253：库标记（`.ppf/`）在写位置时就建出——启动时「库在不在」只认它，新选的空目录
        // 不能在第一次开库前被判成「库找不到」。
        std::fs::create_dir_all(Path::new(&library).join(".ppf"))
            .map_err(|e| config::set_library_io_err(&e))?;
        // #1260：库 ID——选的是已有的 P-Pass 库就沿用它的 ID（本机数据跟着走），新目录就生成一个；
        // 记进本机，之后库盘上的 ID 与它不同就是别的库，不往里写。
        let id = crate::layout::ensure_library_id(Path::new(&library))
            .map_err(|e| config::set_library_io_err(&e))?;
        crate::layout::record_library_id(&self.platform_dir, &id)
            .map_err(|e| config::ui_err("ui.err_set_library", &[("err", &e)]))?;
        if let Some(store) = &self.store {
            store
                .write(library.as_bytes())
                .map_err(|e| config::ui_err("ui.err_set_library", &[("err", &e)]))?;
        }
        // #1238：窗口程序要读得到这份 config（判断「配过没有」、找照片库）。Windows 服务形态
        // 下目录私有，给这一个文件授本机用户只读；授不上就报错——否则服务一停，窗口程序
        // 又会把已配置的机器当成全新安装。
        {
            use platform::PlatformAdapter as _;
            platform::adapter()
                .share_config_read(&cfg)
                .map_err(|e| config::ui_err("ui.err_set_library", &[("err", &e)]))?;
        }
        Ok(cfg)
    }

    /// #1246：常驻 daemon 每次启动时重新给 config.toml 授窗口程序只读（[`Self::set`] 同一授权）。
    ///
    /// 这条 ACE 只有 daemon 授，但外部操作会把它冲掉：安装器升级时 `icacls /reset` 把
    /// ProgramData 的子项重置成只继承父目录，窗口程序读不到 config.toml，就把已配置的机器
    /// 当成全新安装（退回首启向导）。启动时幂等补授一次，正本仍只在 daemon，任何冲刷下次
    /// 启动都自愈。config.toml 不存在（未配置）时什么都不做。授不上只告警、不阻断启动——
    /// 照片和配对比向导显示更要紧。
    pub fn reshare_config(&self) {
        use platform::PlatformAdapter as _;
        match self.reshare_config_with(|cfg| platform::adapter().share_config_read(cfg)) {
            Some(Ok(platform::Applied::Done)) => {
                tracing::info!("#1246: config.toml 已对本机用户只读共享")
            }
            Some(Ok(_)) | None => {}
            Some(Err(e)) => {
                tracing::warn!("#1246: config.toml 授本机用户只读失败（窗口程序可能退回向导）：{e}")
            }
        }
    }

    /// [`Self::reshare_config`] 的可测部分：config.toml 存在才调 `share`。
    fn reshare_config_with(
        &self,
        share: impl FnOnce(&Path) -> platform::Result<platform::Applied>,
    ) -> Option<Result<platform::Applied, String>> {
        let cfg = self.platform_dir.join(CONFIG_FILE_NAME);
        cfg.exists().then(|| share(&cfg).map_err(|e| e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    #[derive(Default, Clone)]
    struct Mem(Arc<Mutex<Option<Vec<u8>>>>);
    impl platform::SecretBlobStore for Mem {
        fn read(&self) -> platform::Result<Option<Vec<u8>>> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn write(&self, b: &[u8]) -> platform::Result<()> {
            *self.0.lock().unwrap() = Some(b.to_vec());
            Ok(())
        }
        fn delete(&self) -> platform::Result<()> {
            *self.0.lock().unwrap() = None;
            Ok(())
        }
        fn location(&self) -> String {
            "mem".into()
        }
    }

    fn resident(loc: &LibraryLocation) -> ResidentLibrary {
        let cfg = Config::load(Some(&loc.platform_dir.join(CONFIG_FILE_NAME))).unwrap();
        loc.resident_library(&cfg).unwrap()
    }

    /// 有正本时：没配置过 ⇒ 未配置；写过 ⇒ 用正本；**改 config.toml 不生效**。
    /// 反证：resident_library 改成读 config.data_dir ⇒ 最后一条红。
    #[test]
    fn with_a_secure_store_only_the_store_counts() {
        let tmp = tempfile::tempdir().unwrap();
        let mem = Mem::default();
        let loc = LibraryLocation::with(Some(Box::new(mem.clone())), tmp.path().join("platform"));
        assert_eq!(resident(&loc), ResidentLibrary::Unconfigured);

        let lib = tmp.path().join("Library A");
        loc.set(lib.to_str().unwrap(), None).unwrap();
        assert!(lib.is_dir(), "首启建库目录");
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib.clone(),
                configured: true
            }
        );

        // 同用户程序把 config.toml 改到别处：daemon 不认。
        std::fs::write(
            loc.platform_dir.join(CONFIG_FILE_NAME),
            "data_dir = \"/tmp/attacker-library\"\n",
        )
        .unwrap();
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib,
                configured: true
            }
        );
    }

    /// 改库走校验：目标不存在 ⇒ 报错、正本不动。
    #[test]
    fn changing_the_library_is_validated_and_keeps_the_store_on_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let mem = Mem::default();
        let loc = LibraryLocation::with(Some(Box::new(mem.clone())), tmp.path().join("platform"));
        let a = tmp.path().join("a");
        loc.set(a.to_str().unwrap(), None).unwrap();
        let err = loc
            .set(tmp.path().join("missing").to_str().unwrap(), None)
            .unwrap_err();
        assert!(err.contains("ui.err_library_target_missing"), "{err}");
        assert_eq!(
            mem.0.lock().unwrap().as_deref(),
            Some(a.to_str().unwrap().as_bytes())
        );
        let b = tmp.path().join("b");
        std::fs::create_dir_all(&b).unwrap();
        loc.set(b.to_str().unwrap(), None).unwrap();
        assert_eq!(
            mem.0.lock().unwrap().as_deref(),
            Some(b.to_str().unwrap().as_bytes())
        );
    }

    /// 没有安全存储的平台：沿用 config 语义（没配置 ⇒ 平台目录、非显式）。
    /// Windows / Linux：没有 config.toml ⇒ 未配置（与 macOS 正本为空同一口径，首启一次性拉起的
    /// daemon 不先在平台目录开库）；有 config.toml 但没写 data_dir ⇒ 平台目录（老配置）。
    /// 反证：去掉「没有 config.toml」那一支 ⇒ 第一条断言变回 At{platform}，红。
    #[test]
    fn without_a_secure_store_config_toml_is_the_authority() {
        let tmp = tempfile::tempdir().unwrap();
        let platform = tmp.path().join("platform");
        let loc = LibraryLocation::with(None, platform.clone());
        assert_eq!(resident(&loc), ResidentLibrary::Unconfigured);
        std::fs::create_dir_all(&platform).unwrap();
        std::fs::write(
            platform.join(CONFIG_FILE_NAME),
            "bind_addr = \"0.0.0.0:41145\"\n",
        )
        .unwrap();
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: platform.clone(),
                configured: false
            }
        );
        std::fs::remove_file(platform.join(CONFIG_FILE_NAME)).unwrap();
        let lib = tmp.path().join("lib");
        loc.set(lib.to_str().unwrap(), None).unwrap();
        assert_eq!(
            resident(&loc),
            ResidentLibrary::At {
                dir: lib,
                configured: true
            }
        );
    }

    /// #1246：config.toml 在就补授（升级冲掉的 ACE 靠这里自愈），不在（未配置）就不碰。
    /// 反证：`reshare_config_with` 不看文件是否存在、或不调 `share` → 红。
    #[test]
    fn startup_reshares_config_only_when_it_exists() {
        let tmp = tempfile::tempdir().unwrap();
        let platform = tmp.path().join("platform");
        let loc = LibraryLocation::with(None, platform.clone());
        let mut calls = Vec::new();
        assert!(loc
            .reshare_config_with(|p| {
                calls.push(p.to_path_buf());
                Ok(platform::Applied::Done)
            })
            .is_none());
        assert!(calls.is_empty(), "未配置时不该授权");

        std::fs::create_dir_all(&platform).unwrap();
        std::fs::write(platform.join(CONFIG_FILE_NAME), "").unwrap();
        let out = loc.reshare_config_with(|p| {
            calls.push(p.to_path_buf());
            Ok(platform::Applied::Done)
        });
        assert_eq!(out, Some(Ok(platform::Applied::Done)));
        assert_eq!(calls, vec![platform.join(CONFIG_FILE_NAME)]);
    }

    // ── #1826：敏感目录直接拒绝 ────────────────────────────────────────

    /// 假的家目录、应用目录与默认库位置（判据是纯函数，不需要真建这些目录）。
    fn fake_env() -> LocationEnvironment {
        let mut env = LocationEnvironment::from_facts(platform::UserDirFacts::from_home(
            PathBuf::from("/Users/tester"),
        ));
        env.app_dirs = vec![
            PathBuf::from("/Users/tester/Library/Application Support/P-Pass"),
            PathBuf::from("/Users/tester/Applications/P-Pass.app/Contents/MacOS"),
            // 打包产物：bundle 根也是安装目录（开发版装在 ~/Applications）。
            PathBuf::from("/Users/tester/Applications/P-Pass.app"),
        ];
        env
    }

    fn kind_of(p: &str) -> Option<SensitiveKind> {
        sensitive_kind(Path::new(p), &fake_env())
    }

    /// 每一类都点名：系统目录、卷根、家目录、用户标准目录、同步盘、应用自身。
    /// 反证：删掉 [`sensitive_kind`] 里任一类判断 ⇒ 对应断言变红（`None`）。
    ///
    /// 全是名字层面的判据（不碰磁盘），Windows 上跑同一张表结论一样；Windows 的
    /// 盘符根形状另由 [`volume_root_shape_covers_both_platform_shapes`] 覆盖。
    #[test]
    fn every_sensitive_category_is_rejected() {
        use SensitiveKind::*;
        let cases: &[(&str, SensitiveKind)] = &[
            // 系统根与系统目录（目录本身 + 系统装软件的归档处内部）。
            ("/", SystemDir),
            ("/System", SystemDir),
            ("/System/Library/Assets", SystemDir),
            ("/Library", SystemDir),
            ("/Library/Preferences", SystemDir),
            ("/Applications", SystemDir),
            ("/Applications/P-Pass.app/Contents", SystemDir),
            ("/Users", SystemDir),
            ("/private", SystemDir),
            ("/tmp", SystemDir),
            ("/var", SystemDir),
            ("/Volumes", SystemDir),
            // Windows 的系统目录名（判据只看名字分量，Windows 上同样命中）。
            ("/Windows/System32", SystemDir),
            ("/Program Files/P-Pass", SystemDir),
            ("/ProgramData/P-Pass", SystemDir),
            // 可移动卷的根目录（只允许卷内专用子目录）。
            ("/Volumes/Backup", VolumeRoot),
            ("/Volumes/Backup/", VolumeRoot),
            ("/mnt/data", VolumeRoot),
            ("/media/tester/USB", VolumeRoot),
            ("/media/USB", VolumeRoot),
            // 家目录本身。
            ("/Users/tester", HomeDir),
            ("/Users/Tester/", HomeDir),
            // 用户标准目录及内部（含「图片」里除默认库位置以外的一切）。
            ("/Users/tester/Desktop", UserDir),
            ("/Users/tester/Desktop/照片", UserDir),
            ("/Users/tester/DESKTOP", UserDir),
            ("/Users/tester/Documents/ppass", UserDir),
            ("/Users/tester/Downloads", UserDir),
            ("/Users/tester/Library/Caches/ppass", UserDir),
            ("/Users/tester/Pictures", UserDir),
            ("/Users/tester/Pictures/Photos", UserDir),
            ("/Users/tester/Pictures/P-Pass Library 2", UserDir),
            ("/Users/tester/Movies", UserDir),
            ("/Users/tester/Music", UserDir),
            // 同步 / 云盘目录及内部。
            ("/Users/tester/Dropbox", CloudDir),
            ("/Users/tester/Dropbox/Photos", CloudDir),
            ("/Users/tester/OneDrive - Contoso/x", CloudDir),
            ("/Users/tester/Google Drive/My Drive/x", CloudDir),
            (
                "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/x",
                CloudDir,
            ),
            ("/Users/tester/Library/CloudStorage/Dropbox/x", CloudDir),
            // 同步盘不只在家目录下判：外置盘 / 其它盘上的同步目录同样拒绝。
            ("/srv/OneDrive/Photos", CloudDir),
            ("/Volumes/Backup/Dropbox/x", CloudDir),
            // 应用自身：数据目录与安装目录。
            ("/Users/tester/Library/Application Support/P-Pass", AppDir),
            (
                "/Users/tester/Library/Application Support/P-Pass/lib",
                AppDir,
            ),
            (
                "/Users/tester/Applications/P-Pass.app/Contents/MacOS/ppf-daemon",
                AppDir,
            ),
            (
                "/Users/tester/Applications/P-Pass.app/Contents/Resources",
                AppDir,
            ),
        ];
        for (path, want) in cases {
            assert_eq!(kind_of(path), Some(*want), "{path} 应判成 {want:?}");
        }
    }

    /// 普通独立目录不受影响：家目录里的普通子目录、应用默认库位置、卷内的专用子目录、
    /// 系统位置之外的自定义位置。
    /// 反证：把 [`sensitive_kind`] 改成「凡在家目录下就拒绝」⇒ 前几条红。
    #[test]
    fn ordinary_standalone_folders_are_allowed() {
        for path in [
            "/Users/tester/personal/PPASS_STORAGE",
            "/Users/tester/Photo Library",
            "/Users/tester/Desktop-old", // 名字像，但不是桌面本身
            "/Users/tester/Dropbox-old",
            "/Users/tester/personal/box", // 普通文件夹，不是 Box 同步盘
            "/Users/tester/Pictures/P-Pass Library", // 应用自己的默认库位置（唯一例外）
            "/Users/tester/Pictures/P-Pass 家庭照片库", // 改名前的默认库位置
            "/Volumes/Backup/PPASS_STORAGE",
            "/Volumes/Backup/photos",
            "/opt/ppass",
            "/srv/ppass",
            "/private/var/folders/xy/ppass", // 系统临时目录（$TMPDIR）照常放行
        ] {
            assert_eq!(kind_of(path), None, "{path} 不该被拒绝");
        }
    }

    /// 卷根的形状判据：macOS/Linux 的挂载点根、Windows 的盘符根各自命中，卷内子目录放行。
    /// 反证：删掉 [`volume_root_shape`] 的「有根、无父、只剩盘符」那条 ⇒ 第一条红。
    #[test]
    fn volume_root_shape_covers_both_platform_shapes() {
        let c = |v: &[&str]| -> Vec<String> { v.iter().map(|s| (*s).to_string()).collect() };
        // Windows：`C:\`（有根、无父、分量只剩盘符前缀）。
        assert!(volume_root_shape(true, true, true, &c(&[])));
        // macOS / Linux 的挂载点根。
        assert!(volume_root_shape(
            true,
            false,
            false,
            &c(&["volumes", "backup"])
        ));
        assert!(volume_root_shape(true, false, false, &c(&["mnt", "data"])));
        assert!(volume_root_shape(true, false, false, &c(&["media", "usb"])));
        assert!(volume_root_shape(
            true,
            false,
            false,
            &c(&["media", "tester", "usb"])
        ));
        // 卷内的专用子目录放行。
        assert!(!volume_root_shape(
            true,
            false,
            false,
            &c(&["volumes", "backup", "ppass_storage"])
        ));
        assert!(!volume_root_shape(
            true,
            false,
            false,
            &c(&["media", "tester", "usb", "ppass"])
        ));
        // 相对路径的 `C:`（不带分隔符）不是卷根；`/` 归系统目录。
        assert!(!volume_root_shape(false, true, true, &c(&[])));
        assert!(!volume_root_shape(true, true, false, &[]));
    }

    /// 判的是**解析链接后的真实路径**：链到桌面 / 文稿的入口与直接选它一样挡，
    /// 链到普通目录的入口照常放行。链接形态按平台轮一遍（平台知识在 `crates/platform`
    /// 的 test-support 里，daemon 不自己 `std::os::*`）。
    /// 反证：去掉 [`resolve_components`] 里逐段 `canonicalize` ⇒ 第一组断言红。
    #[test]
    fn links_are_resolved_before_judging() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(home.join("Documents").join("real_lib")).unwrap();
        std::fs::create_dir_all(home.join("Desktop")).unwrap();
        std::fs::create_dir_all(home.join("personal").join("PPASS_STORAGE")).unwrap();
        let env =
            LocationEnvironment::from_facts(platform::UserDirFacts::from_home(real_path(&home)));

        for (i, kind) in platform::test_support::dir_link_kinds().iter().enumerate() {
            // 普通目录的别名 → 放行。
            let ok_link = tmp.path().join(format!("storage-link-{i}"));
            if let Err(e) = kind.make(&home.join("personal").join("PPASS_STORAGE"), &ok_link) {
                assert!(kind.may_need_privilege, "{kind:?} 建不出来：{e}");
                eprintln!("跳过 {kind:?}：本机建不了这种链接（{e}）");
                continue;
            }
            assert_eq!(sensitive_kind(&real_path(&ok_link), &env), None, "{kind:?}");

            // 链到文稿里的目录 → 按真实路径判成用户目录。
            let bad_link = tmp.path().join(format!("docs-link-{i}"));
            kind.make(&home.join("Documents").join("real_lib"), &bad_link)
                .unwrap();
            assert_eq!(
                sensitive_kind(&real_path(&bad_link), &env),
                Some(SensitiveKind::UserDir),
                "{kind:?}"
            );

            // 链到桌面本身也挡。
            let desktop_link = tmp.path().join(format!("desktop-link-{i}"));
            kind.make(&home.join("Desktop"), &desktop_link).unwrap();
            assert_eq!(
                sensitive_kind(&real_path(&desktop_link), &env),
                Some(SensitiveKind::UserDir),
                "{kind:?}"
            );
        }

        // 目标还不存在时，取最深的可解析祖先：<home>/Desktop/新文件夹 仍判成用户目录。
        let not_yet = home.join("Desktop").join("新文件夹");
        assert_eq!(
            sensitive_kind(&real_path(&not_yet), &env),
            Some(SensitiveKind::UserDir)
        );
    }

    /// `..` 按真实路径回退，不是字面拼接：`~/Desktop/..` 是家目录本身（挡），
    /// `~/Desktop/../Desktop/x` 仍是桌面里的目录（挡）；`..` 退到根之上解析不出来，
    /// 调用方必须拒绝而不是按字面放行。
    ///
    /// 文件系统部分用隔离临时目录、期望值用平台对同一输入的真实表示（Windows 的
    /// `canonicalize` 返回 `\\?\` 扩展路径，不期待 POSIX 字面量）；解析失败那组
    /// （`/..`、`..`）是纯路径形状，任意平台结论一致。
    /// 反证：把 [`resolve_components`] 的 `ParentDir` 改成「原样 push」⇒ 前三条红。
    #[test]
    fn dot_dot_is_resolved_not_taken_literally() {
        let tmp = tempfile::tempdir().unwrap();
        let home = real_path(&tmp.path().join("home"));
        std::fs::create_dir_all(&home).unwrap();
        let env = LocationEnvironment::from_facts(platform::UserDirFacts::from_home(home.clone()));
        // `Desktop` 还不存在：`..` 回退后停在已存在的家目录上。
        let dotted = home.join("Desktop").join("..");
        assert_eq!(
            resolve_components(&dotted),
            Some(home.clone()),
            "…/Desktop/.. 就是家目录本身（按平台对家目录的真实表示）"
        );
        assert_eq!(
            sensitive_kind(&resolve_components(&dotted).unwrap(), &env),
            Some(SensitiveKind::HomeDir)
        );
        assert_eq!(
            sensitive_kind(
                &resolve_components(&home.join("Desktop").join("../Desktop/x")).unwrap(),
                &env
            ),
            Some(SensitiveKind::UserDir)
        );
        assert_eq!(
            sensitive_kind(
                &resolve_components(&home.join("personal").join("../Downloads/x")).unwrap(),
                &env
            ),
            Some(SensitiveKind::UserDir)
        );
        // 解析不出来：退到根之上 / 相对路径退到空。
        assert_eq!(resolve_components(Path::new("/..")), None);
        assert_eq!(resolve_components(Path::new("..")), None);
        assert_eq!(
            resolve_components(Path::new("/Users/tester/../../..")),
            None
        );

        // 入口处：解析不出来的位置直接报错，一个目录都不建。
        let platform_dir = tmp.path().join("platform");
        let err = check_library_path(Path::new("/.."), &platform_dir, None).unwrap_err();
        assert!(err.contains("ui.err_library_target_missing"), "{err}");
    }

    /// 校验入口 run 在**创建库目录、写 config 之前**：命中敏感目录时磁盘上什么都不留，
    /// 正本不动。全程在临时沙盒里、用合成 PeerUser 造出「主人的用户标准目录」，
    /// 不碰真实用户目录。反证：把 `init_config` / `set_library` 开头那行
    /// `check_library_location` 删掉 ⇒ 这里两条都红（错误变成别的、目录被建出来）。
    #[test]
    fn sensitive_targets_are_refused_before_anything_is_written() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let peer = platform::PeerUser::new(
            "S-1-5-21-1".into(),
            platform::UserDirFacts::from_home(real_path(&home)),
        );
        let target = home.join("Documents").join("ppass-1826-should-not-exist");
        let platform_dir = tmp.path().join("platform");

        // 首启：不建库目录、不写 config.toml。
        let err = config::init_config_with(
            &platform_dir,
            target.to_str().unwrap(),
            config::LocationCheck::Selection { peer: Some(&peer) },
        )
        .unwrap_err();
        assert!(err.contains("ui.err_library_sensitive"), "{err}");
        assert!(!target.exists(), "命中敏感目录时不许建库目录");
        assert!(
            !platform_dir.join(CONFIG_FILE_NAME).exists(),
            "不许写 config"
        );

        // 改库：正本与 config.toml 都保持原样。
        let mem = Mem::default();
        let loc = LibraryLocation::with(Some(Box::new(mem.clone())), platform_dir.clone());
        let good = tmp.path().join("good");
        loc.set(good.to_str().unwrap(), None).unwrap();
        let before = mem.0.lock().unwrap().clone();
        let err = loc
            .set(home.join("Downloads").to_str().unwrap(), Some(&peer))
            .unwrap_err();
        assert!(err.contains("ui.err_library_sensitive"), "{err}");
        assert_eq!(mem.0.lock().unwrap().clone(), before, "正本不许改");
        assert!(!home.join("Downloads").join(LIBRARY_MARKER).exists());
    }

    /// 应用自己的默认库位置放行：「图片」下的 `P-Pass Library`（现默认）与
    /// `P-Pass 家庭照片库`（改名前的默认）；「图片」本身和别的子目录照常拒绝。
    /// 反证：去掉 [`sensitive_kind`] 里 `default_libraries` 那条例外 ⇒ 前两条红。
    #[test]
    fn default_library_locations_are_allowed() {
        use platform::PlatformAdapter as _;
        let pictures = platform::adapter()
            .pictures_dir()
            .expect("测试机有「图片」目录");
        let tmp = tempfile::tempdir().unwrap();
        let platform_dir = tmp.path().join("platform");
        for name in [DEFAULT_LIBRARY_DIR_NAME, LEGACY_DEFAULT_LIBRARY_DIR_NAME] {
            let dir = pictures.join(name);
            check_library_path(&dir, &platform_dir, None)
                .unwrap_or_else(|e| panic!("默认库位置 {name} 不该被拒绝：{e}"));
        }
        for dir in [
            pictures.clone(),
            pictures.join("其他照片"),
            pictures.join("P-Pass Library 2"),
        ] {
            let err = check_library_path(&dir, &platform_dir, None).unwrap_err();
            assert!(
                err.contains("ui.err_library_sensitive"),
                "{}: {err}",
                dir.display()
            );
        }
    }

    /// 「图片」被重定向到别的盘：它自己与其它子目录拒绝，只有两个默认库名放行。
    /// 反证：`sensitive_kind` 不看真实 `pictures`（只靠家目录下的 `pictures` 名字）⇒ 第一条红。
    #[test]
    fn a_redirected_pictures_folder_is_still_sensitive_except_the_default_library() {
        let env = LocationEnvironment::from_facts(platform::UserDirFacts {
            home: Some(PathBuf::from("/Users/tester")),
            pictures: Some(PathBuf::from("/Volumes/Data/PhotoArchive")),
            ..Default::default()
        });
        let k = |p: &str| sensitive_kind(Path::new(p), &env);
        assert_eq!(
            k("/Volumes/Data/PhotoArchive"),
            Some(SensitiveKind::UserDir),
            "重定向后的「图片」本身要拒"
        );
        assert_eq!(
            k("/Volumes/Data/PhotoArchive/2026"),
            Some(SensitiveKind::UserDir),
            "「图片」里的其它子目录要拒"
        );
        for name in [DEFAULT_LIBRARY_DIR_NAME, LEGACY_DEFAULT_LIBRARY_DIR_NAME] {
            assert_eq!(
                k(&format!("/Volumes/Data/PhotoArchive/{name}")),
                None,
                "默认库位置 {name} 放行"
            );
        }
    }

    /// `/private/tmp` 与 `/private/var` 精确拒绝（macOS 上 `/tmp`、`/var` 的真实路径），
    /// 它们的子目录照常放行（`/private/var/folders` 是系统临时目录）。
    /// 反证：删掉 `is_system_dir` 里那条精确匹配 ⇒ 前两条红。
    #[test]
    fn private_tmp_and_var_are_rejected_exactly() {
        assert_eq!(kind_of("/private/tmp"), Some(SensitiveKind::SystemDir));
        assert_eq!(kind_of("/private/var"), Some(SensitiveKind::SystemDir));
        assert_eq!(kind_of("/private/tmp/ppass"), None, "子目录照常放行");
        assert_eq!(kind_of("/private/var/folders/xy/ppass"), None);
    }

    /// 用户标准目录不止「图片」会被重定向：文稿 / 桌面 / 下载等被系统或 symlink 挪到家
    /// 目录之外后，按家目录下的名字判不到，必须按**真实位置**逐个拒——家目录之外的同
    /// 盘其它目录不受牵连。
    /// 反证：`sensitive_kind` 删掉 `env.user_dirs` 那条 ⇒ 前四条红（第四条也红：入口把
    /// 解析后的真实位置放行）。
    #[test]
    fn redirected_user_dirs_are_rejected_at_their_real_locations() {
        let env = LocationEnvironment::from_facts(platform::UserDirFacts {
            home: Some(PathBuf::from("/Users/tester")),
            desktop: Some(PathBuf::from("/Volumes/Data/Desk")),
            documents: Some(PathBuf::from("/Volumes/Data/PersonalDocs")),
            downloads: Some(PathBuf::from("/Volumes/Data/Downloads")),
            library: None,
            pictures: Some(PathBuf::from("/Users/tester/Pictures")),
            videos: Some(PathBuf::from("/mnt/WinShape/Videos")),
            music: None,
        });
        let k = |p: &str| sensitive_kind(Path::new(p), &env);
        for dir in [
            "/Volumes/Data/PersonalDocs",
            "/Volumes/Data/PersonalDocs/photos",
            "/Volumes/Data/Desk",
            "/Volumes/Data/Downloads/lib",
            "/Volumes/Data/Downloads",
            "/mnt/WinShape/Videos",
            "/mnt/WinShape/Videos/lib",
        ] {
            assert_eq!(k(dir), Some(SensitiveKind::UserDir), "{dir} 该按真实位置拒");
        }
        // 同盘上的其它普通目录不受牵连。
        assert_eq!(k("/Volumes/Data/PPASS_STORAGE"), None);
        assert_eq!(k("/Volumes/Data/OtherDocs"), None);

        // 入口层面：链到家目录外的「文稿」的入口，解析后的真实路径同样被拒。
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let outside = tmp.path().join("PersonalDocs");
        let real_docs = outside.join("photos");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(&real_docs).unwrap();
        for kind in platform::test_support::dir_link_kinds() {
            let entry = home.join("docs-entry");
            let _ = std::fs::remove_file(&entry);
            if let Err(e) = kind.make(&outside, &entry) {
                assert!(kind.may_need_privilege, "{kind:?} 建不出来：{e}");
                continue;
            }
            let mut facts = platform::UserDirFacts::from_home(real_path(&home));
            facts.documents = Some(real_path(&outside));
            let peer = platform::PeerUser::new("S-1-5-21-1".into(), facts);
            let err =
                check_library_path(&entry, &tmp.path().join("platform"), Some(&peer)).unwrap_err();
            assert!(err.contains("ui.err_library_sensitive"), "{kind:?}: {err}");
            let _ = std::fs::remove_file(&entry);
        }
    }

    /// 默认库位置是「真实图片目录 + 默认名」的**词法**位置（走 `platform(peer)` 那条构造）：
    /// 把默认库做成指向桌面的链接，链接本身不能被放行。
    /// 反证：构造默认库例外时对默认库本身 canonicalize ⇒ 本用例红（桌面进了白名单）。
    #[test]
    fn a_linked_default_library_is_not_whitelisted() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let pictures = home.join("Pictures");
        std::fs::create_dir_all(&pictures).unwrap();
        std::fs::create_dir_all(home.join("Desktop")).unwrap();
        for kind in platform::test_support::dir_link_kinds() {
            let link = pictures.join(DEFAULT_LIBRARY_DIR_NAME);
            let _ = std::fs::remove_file(&link);
            let _ = std::fs::remove_dir(&link);
            if let Err(e) = kind.make(&home.join("Desktop"), &link) {
                assert!(kind.may_need_privilege, "{kind:?} 建不出来：{e}");
                continue;
            }
            // 链接就位之后再取环境事实：这才是真实流程（先有默认库、再来选位置）。
            let mut facts = platform::UserDirFacts::from_home(real_path(&home));
            facts.pictures = Some(real_path(&pictures));
            let peer = platform::PeerUser::new("S-1-5-21-1".into(), facts);
            let env = LocationEnvironment::platform(&tmp.path().join("platform"), Some(&peer));
            assert_eq!(
                sensitive_kind(&real_path(&link), &env),
                Some(SensitiveKind::UserDir),
                "{kind:?}：默认库名链到桌面要拒"
            );
            let _ = std::fs::remove_file(&link);
            let _ = std::fs::remove_dir(&link);
        }
    }

    /// 连接方（主人）的目录事实决定判定：`LocationEnvironment::platform(dir, Some(peer))`
    /// 用 peer 的全套用户目录事实（家目录 + 各标准目录的真实位置），默认库位置按 peer 的
    /// 真实「图片」词法拼接；没有 peer 才问平台。期望值用 `real_path` 对同一输入的表示
    /// （不硬编码 POSIX 字面量——Windows 的 canonicalize 返回 `\\?\` 扩展路径）。
    /// 反证：`platform()` 忽略 peer、一律用适配器 ⇒ 前两组断言红。
    #[test]
    fn peer_facts_drive_the_environment() {
        let tmp = tempfile::tempdir().unwrap();
        let facts = platform::UserDirFacts {
            home: Some(tmp.path().join("owner-home").join("h")),
            documents: Some(tmp.path().join("Data").join("PersonalDocs")),
            desktop: Some(tmp.path().join("Data").join("Desk")),
            downloads: Some(tmp.path().join("Data").join("Downloads")),
            pictures: Some(tmp.path().join("Data").join("PhotoArchive")),
            videos: Some(tmp.path().join("Data").join("Videos")),
            music: Some(tmp.path().join("Data").join("Music")),
            library: None,
        };
        let peer = platform::PeerUser::new("S-1-5-21-1".into(), facts.clone());
        let env = LocationEnvironment::platform(&tmp.path().join("platform"), Some(&peer));
        assert_eq!(env.home, facts.home.as_ref().map(|p| real_path(p)));
        let mut expected_user_dirs: Vec<PathBuf> = [
            facts.desktop.as_deref(),
            facts.documents.as_deref(),
            facts.downloads.as_deref(),
            facts.library.as_deref(),
            facts.pictures.as_deref(),
            facts.videos.as_deref(),
            facts.music.as_deref(),
        ]
        .into_iter()
        .flatten()
        .map(real_path)
        .collect();
        expected_user_dirs.sort();
        let mut actual = env.user_dirs.clone();
        actual.sort();
        assert_eq!(actual, expected_user_dirs, "peer 的全套标准目录各就各位");
        let pictures = real_path(facts.pictures.as_ref().unwrap());
        assert_eq!(
            env.default_libraries,
            vec![
                pictures.join(DEFAULT_LIBRARY_DIR_NAME),
                pictures.join(LEGACY_DEFAULT_LIBRARY_DIR_NAME),
            ],
            "默认库位置按 peer 的真实「图片」词法拼接"
        );

        // 没有 peer（签名 socket / 令牌模式）：问平台当前用户的事实。
        let local = LocationEnvironment::platform(&tmp.path().join("platform"), None);
        let current = platform::UserDirFacts::for_current_user();
        let mut expected: Vec<PathBuf> = current.standard_dirs().map(|d| real_path(d)).collect();
        expected.sort();
        let mut actual = local.user_dirs.clone();
        actual.sort();
        assert_eq!(actual, expected, "无连接方时用平台当前用户的事实");
        assert_eq!(local.home, current.home.as_ref().map(|h| real_path(h)));
    }

    /// 有 peer 但取不全主人的用户目录事实（家目录 + 各标准目录）：拒绝本次设置
    /// （不退回服务账户），返回专门的 keyed 错误。反证：把这条早退删掉 ⇒ 变成 Ok /
    /// 别的错误，红。
    #[test]
    fn missing_peer_facts_refuse_the_selection() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("PPASS_STORAGE");
        let complete = platform::UserDirFacts::from_home(PathBuf::from("/h"));
        // 逐个挖掉一个关键事实：每一个都足以拒绝本次选择。
        let mut cases = vec![platform::UserDirFacts::default()];
        for field in [
            "home",
            "desktop",
            "documents",
            "downloads",
            "pictures",
            "videos",
            "music",
        ] {
            let mut facts = complete.clone();
            match field {
                "home" => facts.home = None,
                "desktop" => facts.desktop = None,
                "documents" => facts.documents = None,
                "downloads" => facts.downloads = None,
                "pictures" => facts.pictures = None,
                "videos" => facts.videos = None,
                "music" => facts.music = None,
                _ => unreachable!(),
            }
            cases.push(facts);
        }
        for facts in cases {
            let peer = platform::PeerUser::new("S-1-5-21-1".into(), facts);
            let err =
                check_library_path(&target, &tmp.path().join("platform"), Some(&peer)).unwrap_err();
            assert!(err.contains("ui.err_library_user_dirs"), "{err}");
        }
        // 事实齐全的合成 peer 照常走到敏感目录判定（本用例负例：普通沙盒目录放行）。
        let ok = platform::PeerUser::new("S-1-5-21-1".into(), complete);
        check_library_path(&target, &tmp.path().join("platform"), Some(&ok))
            .unwrap_or_else(|e| panic!("事实齐全时普通目录不该被拒：{e}"));
    }

    /// 默认库自己是指向桌面的链接：拒绝（默认库的例外是**词法位置**，不 canonicalize
    /// 默认库本身，所以链接不会把桌面加白名单）。链到普通独立目录则按目标分类放行。
    /// 反证：构造默认库例外时对默认库本身 canonicalize ⇒ 第一条红。
    #[test]
    fn a_default_library_linked_into_a_user_folder_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(home.join("Pictures")).unwrap();
        std::fs::create_dir_all(home.join("Desktop")).unwrap();
        std::fs::create_dir_all(home.join("personal").join("PPASS_STORAGE")).unwrap();
        let home = real_path(&home);
        let pictures = home.join("Pictures");
        let mut env =
            LocationEnvironment::from_facts(platform::UserDirFacts::from_home(home.clone()));
        env.app_dirs = vec![];
        env.default_libraries = vec![pictures.join(DEFAULT_LIBRARY_DIR_NAME)];

        for (i, kind) in platform::test_support::dir_link_kinds().iter().enumerate() {
            let into_desktop = pictures.join(format!("P-Pass Library {i}"));
            if let Err(e) = kind.make(&home.join("Desktop"), &into_desktop) {
                assert!(kind.may_need_privilege, "{kind:?} 建不出来：{e}");
                continue;
            }
            // 名字不是默认库名 → 用户目录；把名字对上默认库名（另建链接）也一样拒。
            assert_eq!(
                sensitive_kind(&real_path(&into_desktop), &env),
                Some(SensitiveKind::UserDir),
                "{kind:?}：图片里的链接"
            );
            let named_default = home.join("Alt").join(DEFAULT_LIBRARY_DIR_NAME);
            std::fs::create_dir_all(named_default.parent().unwrap()).unwrap();
            if kind.make(&home.join("Desktop"), &named_default).is_ok() {
                assert_eq!(
                    sensitive_kind(&real_path(&named_default), &env),
                    Some(SensitiveKind::UserDir),
                    "{kind:?}：默认库名链到桌面要拒"
                );
            }

            let ok_link = pictures.join(DEFAULT_LIBRARY_DIR_NAME);
            if kind
                .make(&home.join("personal").join("PPASS_STORAGE"), &ok_link)
                .is_ok()
            {
                assert_eq!(
                    sensitive_kind(&real_path(&ok_link), &env),
                    None,
                    "{kind:?}：默认库名链到普通独立目录放行"
                );
            }
        }
    }

    /// #1826：搬迁收尾的 commit 入口只提交已预检过的计划，**不**再当作一次新的位置选择
    /// （重启后没有连接方，拿服务账户的目录事实重判会误拒、把源和目标拆开）。
    /// 全程在临时沙盒里、用合成 PeerUser 造「文稿」位置，不再往真实用户目录建/删任何东西。
    /// 反证：把 `commit_relocated` 改成走 `set` ⇒ 这里第二段红。
    #[test]
    fn committing_a_relocated_plan_does_not_recheck_the_selection() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        std::fs::create_dir_all(&home).unwrap();
        let peer = platform::PeerUser::new(
            "S-1-5-21-1".into(),
            platform::UserDirFacts::from_home(real_path(&home)),
        );
        let loc = LibraryLocation::with(None, tmp.path().join("platform"));
        // 「文稿」里的位置：新选择要拒。
        let target = home.join("Documents").join("ppass-1826-commit");
        let err = loc.set(target.to_str().unwrap(), Some(&peer)).unwrap_err();
        assert!(err.contains("ui.err_library_sensitive"), "{err}");
        assert!(!target.exists(), "拒绝时不许建目录");
        // 同一个位置作为已预检计划的提交：不做选择校验，照常写下去。
        let cfg = loc
            .commit_relocated(target.to_str().unwrap())
            .unwrap_or_else(|e| panic!("提交搬迁计划不该被敏感目录拦下：{e}"));
        assert!(target.join(LIBRARY_MARKER).is_dir());
        assert!(cfg.exists());
        // 清理交给 tempdir：不再手动 remove_dir_all。
    }
}
