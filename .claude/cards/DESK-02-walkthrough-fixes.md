# DESK-02 桌面走查修复三项　级别 L1（2026-08-12 用户真机走查）

## ① 更新通道选项删除——环境由构建推导

用户裁决：通道选择 UI 不要（丑且多余）。构建期 PPF_BUILD_VERSION 已
注入完整 tag：**版本含 `-test.` → test 通道，否则 stable**，零 UI。
页脚版本号显示完整版本串（如 `0.3.2-test.1`），环境信息自带。
Android 端同规则同步处理（设置页通道行一并删除，推导逻辑单测）。
stable URL 红线不变。

## ② 家人与设备：已移除设备不再展示

被移除/吊销的设备还挂在列表里。审计流已有 device.revoked/unpaired
记录（历史可查），列表只展示在用设备。修在 daemon 侧：devices.list
默认过滤 revoked（加 include_revoked 参数默认 false，语义单测），
桌面零改动或只删兜底。

## ③ 二维码弹窗不让路

用户实测：手机扫码后，允许信息出现时 QR 弹窗还挡在上面。代码里
「pending>0 → 关 QR」逻辑在（App.svelte:155），但靠 3 秒轮询——最长
3 秒窗口里 QR 挡住确认列表。修：配对弹窗打开期间轮询加密到 1s（或
pairing.start 后专门起快轮询，弹窗关了停），收到 pending 立即关 QR。

## 可执行验收

1. ①：test 构建页脚显示 `x.y.z-test.N` 且自动走 test 通道；正式构建走
   stable（推导函数单测两分支）；通道 UI 在两端 grep 无残留。
2. ②：集成测试——吊销一台后 devices.list 默认不含它，include_revoked
   =true 时含（反证：过滤去掉 → 测试必红）。
3. ③：模拟扫码注入 pending → QR 弹窗 1s 内关闭且确认列表可见（贴时序）。
4. 全量测试绿 + vite build 绿。

## 收尾
CI 绿；PROGRESS/NEXT 一行；卡移 done/。
