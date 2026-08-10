# DEV-01 设备身份保全 + 重配对识别合并　级别 L2

## 背景（用户痛点 2026-08-10：重装必重配对，且旧设备变僵尸行）

事实链：设备身份 = ed25519 密钥对（identity.key，app 沙盒文件）；
**同签名覆盖安装不丢身份**（多次实证）；丢身份只发生在卸载重装/清
数据——而 manifest 里 `allowBackup="false"`，系统云备份被显式关掉了。
丢了之后新 NodeId = 新设备，daemon 端旧行变「还没备份过」僵尸。
用户约束：**不做自建账号体系**。硬件信息派生身份已否决（身份即凭据，
可猜测的种子=安全塌方；Android 也无稳定硬件 ID）。

## 三段修法（按序交付，每段独立可验）

### ① 身份随系统云备份走（治「卸载重装丢身份」）

`allowBackup="true"` + `fullBackupContent`/`dataExtractionRules` **白名单
只含** identity.key、pairing.json、backup_scope prefs——照片确认缓存/
哈希缓存/水位**排除**（重装后靠 exist-check 校准重建，不该进云备份）。
同 Google 账号卸载重装 → 身份自动恢复 → 不用重配对。
说明写进代码注释：Android 云备份对新设备是端到端加密（锁屏密码派生），
密钥不裸奔；用户不接受此暴露面时关闭系统备份即可回到现状。

### ② 配对请求带指纹提示（为 ③ 提供识别信号）

pair.request 加可选字段 `device_hint`（Build.MODEL + ANDROID_ID 的
SHA-256 前 8 字节 hex）——**只作提示不作凭据**，鉴权语义零变化。
proto 演进按铁律：旧帧字节不变，金样本随行。daemon 存储 hint
（device 表加列，storage migration）。

### ③ 允许时识别旧设备 → 合并（治「僵尸行」）

允许配对时，daemon 发现存量设备中有同 hint（或同名）的旧行 →
确认界面给选项「**替换旧的 <名字>**（继承名字、备份记录、水位）」：
- asset 的 src_device 归属迁移到新 NodeId（或映射表，方案自选写理由）；
- backup_watermark 合并取 max；旧设备行删除；审计 `device.merged`
  （from/to 双 NodeId 入 detail）。
- 选「作为新设备」则维持现状语义。

## 不准动

authz 鉴权语义（hint 绝不参与授权判定）；identity.key 格式与位置；
现有配对确认「绝不默认放行」原则（合并也必须人工确认）。

## 可执行验收

1. ①：备份规则单测/资源断言（白名单精确命中，缓存类文件排除）；
   真机 adb `bmgr` 备份→卸载→装→恢复流程挂验收人。
2. ②：金样本——新旧帧互解；无 hint 的旧客户端配对不受影响（集成测试）。
3. ③：集成测试——旧设备在案 + 同 hint 新配对 → 合并后 asset 归属/
   水位/审计正确，旧行消失；选「新设备」路径不动旧行。
4. 反证：合并后用旧 NodeId 发 hello → 必须被拒（旧身份已删，贴输出）。
5. 全量测试绿 + arch-check 绿。

## 收尾

CI 绿；PROGRESS/NEXT 一行；ROADMAP 状态行；卡移 done/。①②③ 每段
单独 commit，方便单独 revert。
