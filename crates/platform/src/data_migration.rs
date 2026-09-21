//! DESK-24 (#173)：数据目录搬家的**平台无关**内核。
//!
//! 只有 Windows 有遗留位置要搬（`%APPDATA%` → `%LOCALAPPDATA%`，理由见
//! `windows.rs` 的 `data_dir`），但这里面一行 Windows 专属代码都没有：
//! 全是 `rename` / `read_dir`。按本 crate 顶部立的规矩——「纯逻辑放在 cfg
//! 外面，三条 lane 都跑得到；只有系统调用包在 cfg 里」——所以放这儿，
//! 而不是塞进 `windows.rs` 让它只在 Windows lane 上被测。
//!
//! ## 两条死线
//!
//! 1. **不丢数据。**
//! 2. **不出现「索引空了但没人报错」。** 搬迁失败时行为必须与没搬之前
//!    完全一致，绝不半路切到一个空目录上去。
//!
//! ## 怎么做到的
//!
//! [`resolve`] 不写死用哪个目录，而是看**数据实际在哪**：遗留目录还在就用
//! 遗留目录，没了才用新目录。于是「搬迁失败」自动退化成「保持原样」。
//!
//! [`migrate`] 分三步，每一步崩了都能从磁盘上的状态推出该干什么：
//!
//! ```text
//! ① 把遗留目录**整个改名**到新目录旁边的中转名字
//! ② 把中转目录里的条目逐个挪进新目录
//! ③ 中转目录空了就删掉
//! ```
//!
//! 第 ① 步是单次目录改名，同卷原子，**不管里面是 300 字节还是 300 GB 都是
//! 一瞬间**——这不是性能洁癖：用户的 `config.toml` 里如果没写 `data_dir`，
//! 整个照片库就在那个目录里（`daemon/src/main.rs` 的
//! `config.data_dir.unwrap_or(platform_dir)`），逐文件搬会要命。
//!
//! 第 ② 步不能省成「直接把遗留目录改名成新目录」：新目录可能已经存在了
//! （Tauri 的网页视图数据 `EBWebView` 就在里面），改名会失败。
//!
//! **崩在 ① 和 ③ 之间**：下次启动先扫中转目录，接着排。判据是「中转目录
//! 在不在」，不需要额外的状态文件——状态就是磁盘布局本身。

use std::ffi::OsStr;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

/// 一次搬家的结果。
///
/// 为什么不是 `Result<()>`：`Ok(())` 会把「什么都没搬」和「搬了一半」都说成
/// 成功，而这两种状态在这里的后果完全不同。与 [`crate::Applied`] 同一个口径
/// ——把状态摊开，调用方就没法把缺口当成完成。
///
/// **没有一个变体代表「启动应该失败」**：卡面第 2 条要求搬迁失败不得导致
/// 启动失败，这里从类型上就没给出那个选项。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DataDirMigration {
    /// 没有遗留数据要搬。本平台压根没有遗留位置这回事（mac / Linux），
    /// 或者这台机器上那个目录不存在（全新安装、或已经搬完了）。
    NothingToDo,
    /// 搬完了，遗留目录已经不存在。
    Migrated {
        /// 这一趟数据**真实的**来源：正常是遗留目录，接力时是中转目录。
        from: PathBuf,
        to: PathBuf,
        /// 挪过去的顶层条目数。
        moved: usize,
        /// 两边同名、因此老的那份被改名留在旁边的条目。
        conflicts: Vec<PathBuf>,
        /// 这一趟是**接上一次中断的搬迁**，不是从头搬的。
        ///
        /// 单独拎出来是因为日志会被人在出事时读：`from` 指向中转目录那次，
        /// 若不说明，读的人会以为遗留目录刚才还在。
        resumed: bool,
    },
    /// **没搬**，仍然在用遗留位置。功能与搬之前一模一样，下次启动再试。
    ///
    /// 典型原因：遗留目录被重定向到了别的卷（域环境把 `Roaming` 指到网络
    /// 盘——正好是这张卡设想的场景），改名会返回跨设备错误；或者目录里有
    /// 文件正被别的进程占着。
    Deferred { keeping: PathBuf, reason: String },
    /// 搬了一部分就卡住了：中转目录还在，下次启动会接着排。
    ///
    /// 这是**必须被看见**的状态——调用方记 warn，不是 info。
    Partial {
        staging: PathBuf,
        moved: usize,
        remaining: usize,
        reason: String,
    },
}

impl fmt::Display for DataDirMigration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NothingToDo => write!(f, "数据目录：无遗留位置需要搬迁"),
            Self::Migrated {
                from,
                to,
                moved,
                conflicts,
                resumed,
            } => {
                if *resumed {
                    write!(f, "接上一次中断的搬迁：")?;
                }
                write!(
                    f,
                    "数据目录已搬迁：{} → {}（{moved} 项）",
                    from.display(),
                    to.display()
                )?;
                if !conflicts.is_empty() {
                    write!(f, "；两边同名、老的那份已改名留在旁边：")?;
                    for (i, c) in conflicts.iter().enumerate() {
                        if i > 0 {
                            write!(f, "、")?;
                        }
                        write!(f, "{}", c.display())?;
                    }
                }
                Ok(())
            }
            Self::Deferred { keeping, reason } => write!(
                f,
                "数据目录**未**搬迁，继续用 {}（下次启动再试）：{reason}",
                keeping.display()
            ),
            Self::Partial {
                staging,
                moved,
                remaining,
                reason,
            } => write!(
                f,
                "数据目录只搬了一部分：已挪 {moved} 项，还有 {remaining} 项留在中转目录 {}，下次启动会接着排：{reason}",
                staging.display()
            ),
        }
    }
}

impl DataDirMigration {
    /// 记日志时该不该用 warn。`Migrated` 是好消息但也值得记一条 info——
    /// 用户的数据被挪过位置这件事，事后查问题时必须能从日志里看见。
    pub fn is_warning(&self) -> bool {
        matches!(self, Self::Deferred { .. } | Self::Partial { .. })
    }

    /// 无事发生时不值得占一行日志。
    pub fn is_quiet(&self) -> bool {
        matches!(self, Self::NothingToDo)
    }
}

/// **生效的**数据目录：数据在哪就是哪。
///
/// 不写死返回新位置，是为了让「搬迁失败」自动退化成「保持原样」而不是
/// 「指着一个空目录」。这是本模块两条死线里的第二条。
pub fn resolve(legacy: &Path, current: &Path) -> PathBuf {
    if legacy.is_dir() {
        legacy.to_path_buf()
    } else {
        current.to_path_buf()
    }
}

/// 中转目录的名字前缀：`<新目录名>.migrating-<pid>`。
///
/// 必须与新目录**同父**（改名要求同卷），且**不能在新目录里面**（否则第 ②
/// 步排空时会把自己也当成一个条目挪进去）。名字里带上新目录名，是为了让
/// 人在 `%LOCALAPPDATA%` 下看见它时知道这是什么。
fn staging_prefix(current: &Path) -> Option<String> {
    let name = current.file_name()?.to_str()?;
    Some(format!("{name}.migrating-"))
}

fn find_staging(parent: &Path, prefix: &str) -> Option<PathBuf> {
    let mut found: Option<PathBuf> = None;
    for entry in fs::read_dir(parent).ok()?.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with(prefix) {
            continue;
        }
        if !entry.path().is_dir() {
            continue;
        }
        // 多个残骸（理论上不该有）时取名字最小的那个，保证**确定性**：
        // 同一块磁盘状态每次都得出同一个动作，测试才敢断言。
        match &found {
            Some(prev) if prev <= &entry.path() => {}
            _ => found = Some(entry.path()),
        }
    }
    found
}

fn deferred(legacy: &Path, action: &str, e: std::io::Error) -> DataDirMigration {
    DataDirMigration::Deferred {
        keeping: legacy.to_path_buf(),
        reason: format!("{action}失败：{e}"),
    }
}

/// 把 `legacy` 整个搬到 `current`。见模块头的三步说明。
///
/// 幂等：没活干时返回 [`DataDirMigration::NothingToDo`]，连目录都不会建。
pub fn migrate(legacy: &Path, current: &Path) -> DataDirMigration {
    let (Some(parent), Some(prefix)) = (current.parent(), staging_prefix(current)) else {
        return DataDirMigration::Deferred {
            keeping: legacy.to_path_buf(),
            reason: format!("目标路径 {} 没有父目录或名字不是 UTF-8", current.display()),
        };
    };

    // ① 上一次搬到一半留下的中转目录优先——它是那批数据**唯一**的下落
    //    （遗留目录那时已经被改名走了）。先把它排空，这一趟就到此为止；
    //    遗留目录如果又冒出来了（只可能是人手工建的），下次启动再管。
    if let Some(staging) = find_staging(parent, &prefix) {
        // 来源报**中转目录**而不是 legacy：这一趟的数据确实是从那儿拿的，
        // 遗留目录在上一趟就已经被改名走了。
        return drain(&staging, current, &staging.clone(), true);
    }

    if !legacy.is_dir() {
        return DataDirMigration::NothingToDo;
    }

    // ② 整目录改名。失败就保持原样——遗留目录一根汗毛没动。
    if let Err(e) = fs::create_dir_all(parent) {
        return deferred(legacy, "创建目标父目录", e);
    }
    let staging = parent.join(format!("{prefix}{}", std::process::id()));
    if let Err(e) = fs::rename(legacy, &staging) {
        return deferred(legacy, "把遗留目录改名到中转位置", e);
    }

    drain(&staging, current, legacy, false)
}

/// 把中转目录里的顶层条目逐个挪进 `current`，排空后删掉中转目录。
fn drain(staging: &Path, current: &Path, from: &Path, resumed: bool) -> DataDirMigration {
    if let Err(e) = fs::create_dir_all(current) {
        return DataDirMigration::Partial {
            staging: staging.to_path_buf(),
            moved: 0,
            remaining: count_entries(staging),
            reason: format!("创建目标目录失败：{e}"),
        };
    }
    let entries = match fs::read_dir(staging) {
        Ok(it) => it,
        Err(e) => {
            return DataDirMigration::Partial {
                staging: staging.to_path_buf(),
                moved: 0,
                remaining: 0,
                reason: format!("读中转目录失败：{e}"),
            }
        }
    };

    let mut moved = 0usize;
    let mut conflicts = Vec::new();
    let mut first_error: Option<String> = None;

    for entry in entries.flatten() {
        let name = entry.file_name();
        let src = entry.path();
        let plain = current.join(&name);

        // 冲突策略：**新的赢**。新位置已经有同名的，就把老的改名留在旁边，
        // 绝不覆盖、绝不悄悄丢——用户自己看一眼再决定删不删。
        let dest = if plain.exists() {
            match backup_path(current, &name) {
                Some(p) => {
                    conflicts.push(p.clone());
                    p
                }
                None => {
                    first_error.get_or_insert_with(|| {
                        format!("{} 在新位置已存在，且备份名全被占满", plain.display())
                    });
                    continue;
                }
            }
        } else {
            plain
        };

        match fs::rename(&src, &dest) {
            Ok(()) => moved += 1,
            Err(e) => {
                first_error.get_or_insert_with(|| format!("挪 {} 失败：{e}", src.display()));
            }
        }
    }

    // 空了才删得掉；没空说明上面有条目没挪成，留着下次接着排。
    let _ = fs::remove_dir(staging);
    let remaining = count_entries(staging);
    if remaining > 0 || staging.is_dir() {
        return DataDirMigration::Partial {
            staging: staging.to_path_buf(),
            moved,
            remaining,
            reason: first_error.unwrap_or_else(|| "中转目录没能删掉".to_string()),
        };
    }

    DataDirMigration::Migrated {
        from: from.to_path_buf(),
        to: current.to_path_buf(),
        moved,
        conflicts,
        resumed,
    }
}

fn count_entries(dir: &Path) -> usize {
    fs::read_dir(dir)
        .map(|it| it.flatten().count())
        .unwrap_or(0)
}

/// `<名字>.roaming-backup`，占了就 `.roaming-backup.2`、`.3`……
fn backup_path(current: &Path, name: &OsStr) -> Option<PathBuf> {
    let base = name.to_str()?;
    for n in 1..100u32 {
        let candidate = if n == 1 {
            format!("{base}.roaming-backup")
        } else {
            format!("{base}.roaming-backup.{n}")
        };
        let p = current.join(candidate);
        if !p.exists() {
            return Some(p);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, body: &str) {
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).unwrap();
        }
        fs::write(path, body).unwrap();
    }

    fn read(path: &Path) -> String {
        fs::read_to_string(path).unwrap()
    }

    /// 两个目录名刻意和真实的一样，读测试的人不用回头查。
    fn dirs(root: &Path) -> (PathBuf, PathBuf) {
        (
            root.join("Roaming").join("P-Pass"),
            root.join("Local").join("com.p-pass.desktop"),
        )
    }

    #[test]
    fn resolve_sticks_with_the_legacy_dir_while_it_still_exists() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        fs::create_dir_all(&legacy).unwrap();
        fs::create_dir_all(&current).unwrap();

        // 两个都在时必须是遗留的那个——新目录可能只有 EBWebView，
        // 指过去就等于「索引空了但没人报错」。
        assert_eq!(resolve(&legacy, &current), legacy);
    }

    #[test]
    fn resolve_moves_to_the_new_location_once_the_legacy_dir_is_gone() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());

        // 全新安装：两个都不存在。
        assert_eq!(resolve(&legacy, &current), current);

        fs::create_dir_all(&current).unwrap();
        assert_eq!(resolve(&legacy, &current), current);
    }

    #[test]
    fn a_file_named_like_the_legacy_dir_is_not_a_legacy_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        write(&legacy, "不是目录");

        assert_eq!(resolve(&legacy, &current), current);
        assert_eq!(migrate(&legacy, &current), DataDirMigration::NothingToDo);
    }

    #[test]
    fn nothing_to_do_without_a_legacy_dir_and_nothing_gets_created() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());

        assert_eq!(migrate(&legacy, &current), DataDirMigration::NothingToDo);
        // 没活干就一个目录都别建——空跑一次不该在磁盘上留痕迹。
        assert!(!current.exists());
    }

    #[test]
    fn the_whole_directory_moves_and_the_legacy_dir_disappears() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        write(&legacy.join("config.toml"), "data_dir = \"D:/pics\"");
        write(&legacy.join("logs").join("daemon.log"), "第一行");
        write(&legacy.join("keys").join("device-key.dpapi"), "密文");

        let outcome = migrate(&legacy, &current);

        match outcome {
            DataDirMigration::Migrated {
                moved, conflicts, ..
            } => {
                assert_eq!(moved, 3, "config.toml + logs/ + keys/");
                assert!(conflicts.is_empty());
            }
            other => panic!("{other:?}"),
        }
        assert!(!legacy.exists(), "遗留目录必须消失，否则 resolve 还指着它");
        assert_eq!(read(&current.join("config.toml")), "data_dir = \"D:/pics\"");
        // 子目录整棵跟着走。
        assert_eq!(read(&current.join("logs").join("daemon.log")), "第一行");
        assert_eq!(read(&current.join("keys").join("device-key.dpapi")), "密文");
        // 搬完之后生效目录才换过去。
        assert_eq!(resolve(&legacy, &current), current);
    }

    #[test]
    fn data_already_in_the_new_location_is_left_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        // 真实情况：Tauri 的网页视图数据早就在新位置了。
        write(&current.join("EBWebView").join("cache.bin"), "网页缓存");
        write(&legacy.join("config.toml"), "配置");

        assert!(matches!(
            migrate(&legacy, &current),
            DataDirMigration::Migrated { moved: 1, .. }
        ));
        assert_eq!(
            read(&current.join("EBWebView").join("cache.bin")),
            "网页缓存"
        );
        assert_eq!(read(&current.join("config.toml")), "配置");
    }

    #[test]
    fn a_name_on_both_sides_keeps_the_new_one_and_parks_the_old_one() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        write(&current.join("config.toml"), "新的");
        write(&legacy.join("config.toml"), "老的");

        let outcome = migrate(&legacy, &current);

        let DataDirMigration::Migrated { conflicts, .. } = &outcome else {
            panic!("{outcome:?}");
        };
        assert_eq!(conflicts.len(), 1);
        // 新的原地不动。
        assert_eq!(read(&current.join("config.toml")), "新的");
        // 老的改名留在旁边——绝不覆盖、绝不悄悄丢。
        assert_eq!(read(&current.join("config.toml.roaming-backup")), "老的");
        assert!(!legacy.exists());
    }

    #[test]
    fn a_second_collision_does_not_overwrite_the_first_backup() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        write(&current.join("config.toml"), "新的");
        write(&current.join("config.toml.roaming-backup"), "上一轮留下的");
        write(&legacy.join("config.toml"), "这一轮的老的");

        assert!(matches!(
            migrate(&legacy, &current),
            DataDirMigration::Migrated { .. }
        ));
        assert_eq!(read(&current.join("config.toml")), "新的");
        assert_eq!(
            read(&current.join("config.toml.roaming-backup")),
            "上一轮留下的"
        );
        assert_eq!(
            read(&current.join("config.toml.roaming-backup.2")),
            "这一轮的老的"
        );
    }

    #[test]
    fn an_interrupted_migration_is_finished_on_the_next_run() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        // 造一个「第 ① 步成了、第 ② 步崩了」的现场：遗留目录已经不存在，
        // 数据只在中转目录里。这正是卡面第 4 条要的反证起点。
        let staging = current
            .parent()
            .unwrap()
            .join("com.p-pass.desktop.migrating-4242");
        write(&staging.join("config.toml"), "半路上的配置");
        write(&staging.join("logs").join("daemon.log"), "半路上的日志");
        assert!(!legacy.exists());

        let outcome = migrate(&legacy, &current);

        assert!(
            matches!(
                outcome,
                DataDirMigration::Migrated {
                    moved: 2,
                    resumed: true,
                    ..
                }
            ),
            "{outcome:?}"
        );
        assert_eq!(read(&current.join("config.toml")), "半路上的配置");
        assert_eq!(
            read(&current.join("logs").join("daemon.log")),
            "半路上的日志"
        );
        assert!(!staging.exists(), "排空之后中转目录必须删掉");
    }

    #[test]
    fn an_interrupted_migration_wins_over_a_legacy_dir_that_came_back() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        let staging = current
            .parent()
            .unwrap()
            .join("com.p-pass.desktop.migrating-4242");
        write(&staging.join("config.toml"), "中转里的");
        write(&legacy.join("config.toml"), "又冒出来的");

        // 中转目录是上一批数据唯一的下落，必须先救它；遗留目录留到下一趟。
        assert!(matches!(
            migrate(&legacy, &current),
            DataDirMigration::Migrated { moved: 1, .. }
        ));
        assert_eq!(read(&current.join("config.toml")), "中转里的");
        assert!(legacy.exists(), "这一趟不碰遗留目录");

        // 下一趟才轮到它，并且照样不覆盖。
        assert!(matches!(
            migrate(&legacy, &current),
            DataDirMigration::Migrated { moved: 1, .. }
        ));
        assert_eq!(read(&current.join("config.toml")), "中转里的");
        assert_eq!(
            read(&current.join("config.toml.roaming-backup")),
            "又冒出来的"
        );
    }

    #[test]
    fn a_drain_that_cannot_finish_says_partial_and_loses_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let legacy = tmp.path().join("Roaming").join("P-Pass");
        write(&legacy.join("config.toml"), "要紧的配置");
        write(&legacy.join("logs").join("daemon.log"), "要紧的日志");
        // 新目录的位置上蹲着一个**普通文件**：第 ① 步改名进得去，第 ② 步
        // 建目录必炸。这就把 migrate 逼进 Partial —— 遗留目录已经没了、
        // 数据只在中转目录里、新目录是残缺的，最危险的那一格。
        let current = tmp.path().join("Local").join("com.p-pass.desktop");
        write(&current, "我是文件，不是目录");

        let outcome = migrate(&legacy, &current);

        let DataDirMigration::Partial {
            staging,
            moved,
            remaining,
            ..
        } = &outcome
        else {
            panic!("{outcome:?}");
        };
        assert_eq!(*moved, 0);
        assert_eq!(*remaining, 2, "两个条目都还在中转目录里");
        // (b) 一个字节没丢 —— 只是换了个地方等着。
        assert_eq!(read(&staging.join("config.toml")), "要紧的配置");
        assert_eq!(read(&staging.join("logs").join("daemon.log")), "要紧的日志");

        // (c) 把障碍清掉，下一趟必须救得回来。
        fs::remove_file(&current).unwrap();
        let second = migrate(&legacy, &current);
        assert!(
            matches!(
                second,
                DataDirMigration::Migrated {
                    moved: 2,
                    resumed: true,
                    ..
                }
            ),
            "{second:?}"
        );
        assert_eq!(read(&current.join("config.toml")), "要紧的配置");
        assert_eq!(read(&current.join("logs").join("daemon.log")), "要紧的日志");
    }

    #[test]
    fn migrating_twice_is_a_no_op_the_second_time() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, current) = dirs(tmp.path());
        write(&legacy.join("config.toml"), "配置");

        assert!(matches!(
            migrate(&legacy, &current),
            DataDirMigration::Migrated { .. }
        ));
        assert_eq!(migrate(&legacy, &current), DataDirMigration::NothingToDo);
        assert_eq!(read(&current.join("config.toml")), "配置");
    }

    #[test]
    fn an_unusable_target_defers_and_leaves_every_byte_where_it_was() {
        let tmp = tempfile::tempdir().unwrap();
        let (legacy, _) = dirs(tmp.path());
        write(&legacy.join("config.toml"), "配置");
        // 新目录的父路径是个**文件**，建不出目录来——等价于跨卷 / 没权限
        // 那一类「第 ① 步就过不去」的失败。
        let blocker = tmp.path().join("blocked");
        write(&blocker, "我不是目录");
        let current = blocker.join("com.p-pass.desktop");

        let outcome = migrate(&legacy, &current);

        assert!(
            matches!(outcome, DataDirMigration::Deferred { .. }),
            "{outcome:?}"
        );
        // 这是本模块第一条死线：没搬成 = 一个字节都没动。
        assert_eq!(read(&legacy.join("config.toml")), "配置");
        // 而且生效目录仍然是遗留位置——功能与搬之前完全一致。
        assert_eq!(resolve(&legacy, &current), legacy);
    }

    #[test]
    fn deferred_and_partial_are_the_states_that_must_be_seen() {
        let deferred = DataDirMigration::Deferred {
            keeping: PathBuf::from("X"),
            reason: "跨卷".into(),
        };
        let partial = DataDirMigration::Partial {
            staging: PathBuf::from("Y"),
            moved: 1,
            remaining: 2,
            reason: "占用".into(),
        };
        assert!(deferred.is_warning() && !deferred.is_quiet());
        assert!(partial.is_warning() && !partial.is_quiet());

        let nothing = DataDirMigration::NothingToDo;
        assert!(!nothing.is_warning() && nothing.is_quiet());

        let migrated = DataDirMigration::Migrated {
            from: PathBuf::from("A"),
            to: PathBuf::from("B"),
            moved: 3,
            conflicts: vec![],
            resumed: false,
        };
        // 搬迁成功不是警告，但**必须**留下一行日志：用户的数据换过地方
        // 这件事，事后查问题时得能看见。
        assert!(!migrated.is_warning() && !migrated.is_quiet());
    }
}
