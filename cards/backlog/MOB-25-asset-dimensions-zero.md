# MOB-25 查看页尺寸显示 `0×0`　【BACKLOG · 2026-08-19 用户拍板暂不做】

## 现象

照片查看页右上角显示资产尺寸（`"${asset.width}×${asset.height}"`，
`PhotosScreen.kt` 约 533 行，设计稿 M9 定的"头部只有尺寸信息"），真机
实测显示为 **`0×0`**（截图见当日会话）。

## 已知的边界

- **与 MOB-22 的按钮消失无关**——那个是 `fillMaxSize()` 把底部动作区顶出
  屏幕的布局 bug，已修；`0×0` 是元数据本身就是 0。
- **不是 ICON-02 引入的**——`PhotosScreen` 那轮没被动过。

## 没查的部分（下一个 agent 从这里接）

宽高从 daemon 的 `asset` 表来（`crates/.../index.sqlite` 有 `width` /
`height` 两列，实测确实存在这两个字段）。需要定位是哪一环没填：

1. 手机侧上传时有没有提取并上报宽高？
2. daemon 入库时有没有写这两列？（直接查 sqlite：
   `SELECT rel_path, width, height FROM asset ORDER BY added_at DESC LIMIT 10;`）
3. 还是只有走缩略图管线的资产才回填？

先查 2（一条 SQL 就能分清是"没上报"还是"没入库"），再往上追。

## 影响

纯展示问题，不影响备份/取回正确性。用户判断优先级低，暂不做。
