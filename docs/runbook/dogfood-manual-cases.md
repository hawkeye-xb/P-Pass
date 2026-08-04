# DOG-03 半自动 Case 操作单

> 配 `tools/dogfood/night{1,2,3}.sh` 使用。全自动 case 由 night 脚本注入、
> morning-report.sh 对账；下列 case 需要人手（10–30 秒/个）。

## A1 滑杀 App 后不再打开（半自动注入，晨间对账验证）

```bash
# 注入（night2 已含；手动补跑）：
adb shell am force-stop com.hawkeyexb.ppass
# 验证（次晨）：morning-report.sh 里该设备水位仍在推进（4h 周期任务触发）
```

## A3 重启手机不打开 App（半自动）

```bash
# 注入（night2 用 PPF_REBOOT=1 自动做）：
adb reboot
# 开机后【不要打开 App】；次晨对账周期任务注册幸存（水位推进）。
# 注：adb 会话会断，等设备上线再对账。
```

## A7 省电模式/低电量（半自动，预期「不跑」成立 + 文案不吓人）

```bash
# 注入：
adb shell cmd battery set status unknown
adb shell dumpsys deviceidle force-idle        # 模拟 Doze
# 观察：备份页文案应平静（无恐慌性错误）；预期不触发自动备份。
# 还原：
adb shell cmd battery reset
adb shell dumpsys deviceidle unforce
```

## B7 Mac 关机 24h+（跨夜半自动）

```bash
# 注入（night3 用 PPF_SHUTDOWN=1 自动做）：
sudo shutdown -h +5
# 次日开机后：手机侧「电脑不可达」提示时机 + 通知节流是否符合预期
# （B7 验收点：提示出现时机合理、通知不刷屏）。
```

## 鸿蒙 A2-不加白（对照，night1 配套）

- 鸿蒙机**不要**加白（不点 DOG-02 引导卡）。
- 整夜后：确认鸿蒙无自动备份（预期）、三星加白侧正常备份（对照成立）。
- 次日记录对照结论进日报备注。

## C2 蜂窝→家 v6 直连体感速度（需人，鸿蒙）

- 鸿蒙机开飞行模式 → 仅蜂窝；触发「立即备份」；体感/计时记录。
- 路径展示应如实（relay vs 直连）。

## 白天零头（A5/A6/A8、C3、B4/B5 体感走查）

- A5 备份中断 WiFi/飞行：备份中开飞行 → 恢复 → 幂等续传不重不漏。
- A6 备份中杀 App：catch-up 收敛。
- A8 蜂窝手动备份：产品行为未定义——遇到即记录现象（产品拍板项）。
- C3 强制 relay：配 `PPF_RELAY_URLS` 指向 relay 后验证可用 + 速度受限。
- B4/B5 磁盘满/停服务：见 ROADMAP 既有案例（DISK_FULL 双端人话）。

## E1 双机并发（night3 配套）

- 鸿蒙机手动「立即备份」，与三星整夜备份并发。
- 次晨 D1 两设备均推进且无 P0 即通过。
