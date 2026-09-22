# 本机环境状态（不进 git）

> 这个文件记录**开发机本地**的环境事实：路径、设备、本地副本、daemon 状态。
> 它已被 .gitignore 排除，**不会上远端仓库**。任务卡和 docs/ 里不许再写这些。
> 每轮收口时更新；过期的段落直接删。

## 当前环境（2026-08-21 14:35 快照）

```
照片库：   ~/Pictures/P-Pass 家庭照片库
NodeId：   1f1d1e386aae7d33a352b9c620f95a3efa5543d0eacc2420c43b43ec81bbce32
测试机：   三星 SM-S9210（序列 RFCX1040SNE），已配对，App 0.3.5 (10) 全新安装
索引：     18 行 / originals 18 个文件 / staging 0 字节
daemon：   一次性 spawn，launchd 无常驻项（待用户拍板，见 CHECKLIST 决定清单）
旧副本：   ~/P-Pass NAS.bak-blob01-20260820-1615（1.1G，含 549M 真实照片）
           —— 等用户确认后由用户自己删，agent 不动
```

## 真机取证命令（adb 直连读状态，比看日志快）

```bash
adb exec-out "run-as com.hawkeyexb.ppass cat \
  /data/data/com.hawkeyexb.ppass/files/backup-state/<nodeid>/confirmed.json"
adb shell "run-as com.hawkeyexb.ppass cat \
  /data/data/com.hawkeyexb.ppass/shared_prefs/backup_scope.xml"
adb exec-out "run-as com.hawkeyexb.ppass cat \
  /data/data/com.hawkeyexb.ppass/no_backup/androidx.work.workdb" > /tmp/work.db
  # WorkManager 的库在 no_backup/ 不在 databases/；WorkSpec.output 能解出
  # 每次 run 真实上报的 ingested/duplicates
adb shell "content query --uri content://media/external/images/media \
  --projection _id --where 'bucket_id=<id>'" | wc -l
```

存储端对账（手机说的 vs 库里真有的）：把 `confirmed` 的 hash 集合与
`select hex(hash) from asset` 求交集——直接量出"撒谎的张数"。

## 本机对账命令

```bash
# 中转区必须是 0 —— 留下的每个字节都是丢掉的照片
du -sh "$HOME/Pictures/P-Pass 家庭照片库/.ppf/staging"

# 索引行数
sqlite3 "file:$HOME/Pictures/P-Pass 家庭照片库/.ppf/index.sqlite?mode=ro" \
  "select count(*) from asset;"

# 审计时间线（最近 25 条）
sqlite3 -column -header "file:$HOME/Pictures/P-Pass 家庭照片库/.ppf/index.sqlite?mode=ro" \
  "select datetime(ts/1000,'unixepoch','localtime') t, action, coalesce(detail,'') d
   from audit_log order by ts desc limit 25;"

# 本地全量门禁
just ci                                  # fmt + clippy + 全仓测试 + 架构检查
just android-test                        # Android 单测
cd apps/desktop && npx vitest run        # 桌面前端测试
```

## 待用户回答的本地问题（从 CHECKLIST 移来，因为是本机现象）

1. **桌面端「更改…」按钮**：点下去实际发生了什么？弹窗到主窗口后面了，
   还是 `defaultPath` 指向不存在目录导致面板状态怪？设置页的
   「更改照片库位置…」走同一个 `openDialog`，复现不用动首次向导。
2. **向导第三步「设为常驻服务」**：是跳过了还是点了没成？
   现状 `launchctl` 里没有 P-Pass 常驻项，daemon 是一次性 spawn。
   如果是点了没成 = 真问题（开机不自启、崩了不恢复），要开卡。
3. **旧数据副本删不删**：`~/P-Pass NAS.bak-blob01-20260820-1615`（1.1G）。
