# macOS 目录监听到底给我们什么（2026-08-21 实测）

复现命令（诊断工具，默认 ignore）：

```
cargo test -p daemon --test fsevents_shapes -- --ignored --nocapture
```

`notify = "7"` 在 macOS 上用的是 **FSEvents**（`RecommendedWatcher::kind() == Fsevent`）。

## 实测：每种操作真实投递的事件

| 我做的操作 | 系统投递的事件 |
|---|---|
| ① 新建文件 `a.jpg` | `Create(File)` + `Modify(Metadata)` + `Modify(Data)` |
| ② **改写已有文件的内容** | **`Create(File)`** + `Modify(Metadata)` + `Modify(Data)` |
| ③ 同目录改名 `a.jpg`→`b.jpg` | **`Create(File)` on `a.jpg`** + `Modify(Name)` on `a.jpg` + `Modify(Name)` on `b.jpg` |
| ④ 新建嵌套目录 | `Create(Folder)` ×2 |
| ⑤ 移到子目录（库内分类） | `Modify(Name)` on 旧路径 + `Modify(Name)` on 新路径 |
| ⑥ 从库外拖进来 | **`Modify(Name)` on 新路径**（就一条） |
| ⑦ 拖出库外（Finder 删除→废纸篓） | **`Modify(Name)` on 旧路径**（就一条） |
| ⑧ 删单个文件 | `Remove(File)` + `Modify(Name)` |
| ⑨ 批量写 5 个 + `rm -rf sub` | 5×(Create+Modify)，然后 `sub/deep` 同时报 **`Create(Folder)` 和 `Remove(Folder)`** |
| ⑩ 删掉被监听的根目录本身 | `Remove(Folder)` |
| ⑪ 重建同名根目录并写入 | **事件照常投递** —— 句柄没死 |

## 四条结论

### 1. 事件的「类型」基本没有信息量，只有「路径」可信

- ②改写已有文件报的是 `Create`
- ③改名在**旧名字**上报 `Create`
- ⑨删目录时同一路径**同时**报 `Create` 和 `Remove`

原因：FSEvents 在一个时间窗内按路径**合并**所有变化，返回的是一个标志位
掩码；notify 把掩码翻译成多条事件。所以「这个路径上发生过事情」是真的，
「发生的是哪件事」是猜的。

**推论：唯一正确的架构是「事件 = 去看这个路径，磁盘 = 真相」。**
按事件类型分支（看到 Remove 就删索引）必然出错。

### 2. 移动没有配对信息，「进来」和「出去」长得一模一样

⑥拖进来和⑦拖出去，都只有**一条** `Modify(Name)`，落在树内那一侧的路径上。
系统**不告诉你**它是从哪来的、到哪去的。

**推论：判断「这个文件是来了还是走了」只能靠 `stat` 那个路径。**
不能靠事件。

### 3. 根目录被删掉重建，监听不会死

⑩⑪证明的。WATCH-02 排查时我把「FSEvents 句柄在整棵子树被删后失效」列为
**最可能**的假设，实测是**错的**。已用
`watch_survives_the_root_being_deleted_and_recreated` 钉住。

### 4. 批量操作会被压成一批，不是一条一条来

⑨里 5 次写入 + 一次 `rm -rf` 在同一个窗口里全部到齐。这正是「静默窗口
防抖 + 父路径合并 + 增量扫描」这套设计要的形状：**事件多少条不重要，
把受影响的目录去重后扫一遍就行。**
