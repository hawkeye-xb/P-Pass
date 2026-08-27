# MOB-26 照片查看页缺基础手势，应改用成熟方案　【BACKLOG · 2026-08-19】

用户实测反馈："照片查看的时候没法左右快速翻页……我觉得照片查看这部分
应该能够有一个比较成熟的一个库才对。"

## 现状

`PhotosScreen.kt` 的大图查看是自己搭的最小实现：一个 `Box` 套
`Image(contentScale = Fit)`，外加顶部「返回 + 尺寸」和底部两个动作按钮。
**没有** `HorizontalPager`、没有缩放、没有双击放大、没有拖拽关闭——
用户从网格点进来之后只能看当前这一张，退出去再点下一张。

（同轮修掉的 MOB-22 是另一个问题：`fillMaxSize()` 把底部按钮顶出屏幕。
那个是布局 bug，已修，与本卡无关。）

## 缺的能力

1. **左右滑动翻页**（用户明确点名）——网格里点第 N 张进来，应能直接
   划到 N±1，而不是退出重进。
2. 双指缩放 / 双击放大。
3. 下拉关闭（现代图库的标准手势）。
4. 翻页时的预加载（当前是点开才去 daemon 取原图，翻页会一顿一顿）。

## 方向

Compose 侧成熟选择（实施时评估，别直接抄）：

- `androidx.compose.foundation.pager.HorizontalPager`（官方，已在
  compose-foundation 里，**不用新增依赖**）负责翻页；
- 缩放手势可以自己用 `transformable` + `graphicsLayer` 做，或引入
  telephoto / zoomable 这类专门库——**注意评估包体积**，本项目是照片备份
  App，ICON-02 那轮已经因为体积否掉了 material-icons-extended。

优先做 1（HorizontalPager，零新依赖、收益最大），2/3/4 看情况。

## 注意

- 翻页要跟现有的取原图管线接好：`PhotoViewer` 现在是单张 `hash` 驱动，
  改成 pager 后要按 index 驱动并处理"相邻张还没下载完"的中间态。
- 底部动作按钮（保存/分享）作用于**当前页**的资产，翻页后要跟着切。
- 别打破 MOB-22 的布局修复（图片区必须 `weight(1f)`，不能回到
  `fillMaxSize()`，否则底部按钮又会被顶出屏幕）。
