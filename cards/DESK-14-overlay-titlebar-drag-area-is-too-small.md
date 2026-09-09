# DESK-14 Overlay 标题栏隐藏后主窗口拖拽区域过小

> 🟠 状态：进行中
> 级别：L3 · 阻塞：无
> Owner：Hermes / `desk-14-overlay-drag` · Base：`300a8a8`
> 当前节点：调查现有 Overlay 清边与动态拖拽标记；下一步：确定不吞交互的专用拖拽带 DOM/CSS 边界。

## 问题

macOS 桌面端使用 Tauri `titleBarStyle: "Overlay"`，原生红绿灯悬浮在窗口左上角，
传统系统标题栏不再提供整条可拖拽的窗口区域。现有实现只在
`apps/desktop/src/titlebar.js` 给 `.sidebar`、侧栏品牌/导航和向导头部动态添加
`data-tauri-drag-region`。

主界面里侧栏的大部分面积由导航按钮和服务状态控件占用；主内容区顶部没有专门的
拖拽带。首启向导也只有标题文字附近可用。结果是用户避开交互控件后，实际能拖动
窗口的空白区域很小，尤其在主界面上不易发现。

## 期望行为

在保留 macOS 原生红绿灯与 Overlay 标题栏方案的前提下，主界面和首启向导都提供
清晰、连续且足够宽的顶部空白拖拽带。用户可从红绿灯右侧及窗口顶部其余非交互
空白处拖动窗口，不必在侧栏中寻找零碎空隙。

拖拽区不得吞掉按钮、表单、链接、滚动或现有页面操作；Windows/Linux 外观和交互
不得因 macOS 补偿层发生变化。

## 验收标准

- [ ] 主界面：在 macOS 真机运行时，窗口顶部从红绿灯右侧延伸到主内容区的专用
      空白带可拖动窗口；该带视觉上不再只是侧栏内的零碎空白。
- [ ] 首启向导：同样提供顶部连续空白拖拽带，且不会遮挡 `P-Pass` 标题或向导步骤。
- [ ] 交互回归：导航、服务状态、页面按钮、输入控件和内容区滚动均保持原行为；
      可交互子元素本身不得成为 `data-tauri-drag-region` 目标。
- [ ] 自动化：为拖拽区选择/标记逻辑增加或更新 Vitest 覆盖，断言主界面与向导都
      有专用拖拽元素，交互元素不被标记；`cd apps/desktop && pnpm test` 通过。
- [ ] 构建：`cd apps/desktop && pnpm build` 通过。
- [ ] macOS 桌面回归：在默认尺寸与收起侧栏（<1080px）两种宽度下各走查主界面、
      设置页和首启向导，记录截图；确认没有红绿灯遮挡、内容跳动或死区。

## 范围

- 只准动：`apps/desktop/src/App.svelte`、`apps/desktop/src/app.css`、
  `apps/desktop/src/titlebar.js`、`apps/desktop/src/main.js`，以及本卡所需的现有或
  新增桌面 Vitest 文件。
- 不准动：`apps/desktop/src-tauri/tauri.conf.json` 的 `titleBarStyle: "Overlay"`、
  原生窗口控制按钮、业务页面文案/状态语义、非 macOS 平台布局。

## 阻塞与依赖

无。实现后需要 macOS 桌面真机走查；DOM 单测与前端构建不能替代原生窗口拖拽实证。

---

## 实施记录

已认领：先追踪现有 `titlebar.js`、主界面和向导的布局/测试，再以失败 DOM 用例锁定专用拖拽元素与交互边界。

## 备注

`data-tauri-drag-region` 由 Tauri document 级 `mousedown` 委托在事件目标上读取。
现有动态打标方案只给容器加属性，子按钮保持未标记以免吞掉交互；扩展拖拽区时必须
保留这一边界。