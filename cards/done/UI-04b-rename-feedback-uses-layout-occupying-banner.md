# UI-04b 设备改名成功用了占布局空间的提示条，该用脱离文档流的浮层　级别 L2

> ✅ 状态：验收完成（2026-09-10）
> 当前节点：验收人在真实 Tauri 窗口反复改名走查通过，确认标准 Sonner 通知不占布局、
> 位置与形态可接受，且成功/等待/错误三态颜色符合产品 token。
> 最终实现：使用 shadcn-svelte 官方 `Sonner` 组件与 `svelte-sonner` 通知原语；不再复用
> `Notice`，也没有保留手写 `Toast` / `Message`。`safe` / `waiting` / `act` token 分别映射
> 成功 / 等待提醒 / 错误需处理。
> 验收：用户实窗视觉通过；桌面 Vitest **57/57**（26 files，0 failed）与 `pnpm build` 通过。
> 协同分支：`work/UI-04b-toast`
> 级别：L2 · 已关闭

## 问题

2026-08-26 真机走查，验收人反馈：

> 「修改设备名称，不应该用常驻通知（多秒后消失，也合理），但是占用了布局
> 空间了，正常不都是脱离文档流么。」

改名成功是**瞬时反馈**，几秒后消失是对的；但它现在跟常驻提示同款渲染，会把
下面的内容顶下去、消失时又弹回来。瞬时反馈应该**脱离文档流**（浮层 /
Snackbar），不参与布局。

## 期望行为

瞬时反馈（改名成功、复制成功一类）走浮层，**不参与布局**；视觉上是紧凑且
居中的瞬时反馈，不是占据宽大的黄色提示条。

## 验收标准

- [x] 走查：改名反馈出现与消失时，**下方内容不发生位移**，且视觉上居中、紧凑，
      不再是当前被验收人拒绝的宽大提示条。

## 验收回退记录（2026-09-09；DESK-15 后已校正实现描述）

- 验收人裁决：实现方式（脱离文档流）正确，但组件外观不通过；本卡不得以
  `position: fixed` 的源码断言替代视觉验收。
- `DESK-15` 后已核实：两处调用改为独立 `Notice` 组件；但其黄色横条视觉只是把
  旧样式原样收编，尚未形成适合瞬时反馈的组件合同。本卡按实际代码改为 `Toast`，
  不再复活页面内裸元素或共享 CSS。

## 实施记录（2026-09-08）

- `flashMessage()` 机制复用：同一 `message` 状态 + 5s 自动消失 + 手动 ×，零改动。
- `.message` 呈现改为 `position: fixed` 浮层（top 16px 居中，z-index 60 高于
  modal-backdrop 50），脱离文档流，出现/消失不参与布局。
- 错误反馈（`ui.rename_failed` 等）同机制仍可见，无回归。
- 新增 `src/renameFeedback.test.js` 源码级守卫（photoWall.test.js 同款约定）：
  断言 `.message` 必须 `position: fixed`、不得有 `margin: 0 0 18px` 占位、
  z-index 60 > modal-backdrop 50、改名成功/失败仍走 `flashMessage`。
  反证：临时改回 in-flow（margin 占位）→ 2 条断言真红。
- 桌面 Vitest 6 文件 / 43 tests 全绿（基线 5/40 + 新增 3）；`pnpm build`（vite build）成功。

## 实施记录（2026-09-10，进行中）

- `App.svelte` 的两处瞬时反馈调用改为 `Toast`；原 `Notice` 不再被拿来承载这类
  成功/失败反馈。`Toast` 独占固定定位、内容定宽（最长 360px）、深色高对比外观、
  `role="status"` / `aria-live="polite"` 与关闭按钮可见性。
- 先后完成两轮 RED：先证明页面未接 `Toast`，再证明初始迁移仍保留宽大黄色条；随后
  组件接线和视觉合同转绿。完整桌面 Vitest 由 JSON 报告确认 **59/59** 通过（26 files，
  0 failed），`pnpm build` 通过。
- 已用当前分支 sidecar 启动 Tauri dev；但 CUA 的 macOS 辅助功能/屏幕录制权限 pending，
  未能捕获窗口或触发改名反馈。验收标准的真实视觉走查仍未完成，本卡不得关闭。

## 最终验收记录（2026-09-10）

- 验收人用当前分支的真实 Tauri 窗口反复修改设备名称，先否决手写黑色 `Toast` 与锚在
  设备行旁的手写 `Message`；随后明确接受 shadcn-svelte 官方 Sonner 的右上角形态。
- 最终只保留官方 Sonner 的行为/动效：`toast.success`（绿）、`toast.warning`（黄）、
  `toast.error`（红）。三种背景、描边和文字色直接覆盖为 `safe` / `waiting` / `act`
  token；所有既有短反馈按成功、等待提醒、错误分类接入，不再出现普通色通知。
- 验收人确认最新热更新窗口的绿色改名成功通知显示正确；反馈不占文档流、不挤标题或设备行。

## 范围

- 实际动到：`apps/desktop/src/App.svelte`、`src/app.css`、官方 `src/lib/components/ui/sonner/`、`package.json`/锁文件、`assets/design/tokens.json` 与相邻桌面测试；未改 `NAME-01` 的改名业务语义或 Android UI。
- 不准动：`NAME-01`（设备改名）功能本身、Android UI——本卡只管桌面端这个反馈**怎么呈现**

## 阻塞与依赖

无。⚠️ 与 UI-04a/UI-04c 共享同一处提示呈现层，落地顺序见 UI-04a 备注。
