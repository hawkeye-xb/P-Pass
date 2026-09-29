# Android dataSync 前台服务配额：几分钟内复现「配额耗尽」

Android 15（SDK 35）起，`dataSync` 类型前台服务在 24 小时滚动窗口内累计最多约 6 小时，
到点系统回调 `Service.onTimeout()`，App 须在 `fgs_crash_extra_wait_duration`（本机 10 秒）内停下，
否则进程被杀。真实 6 小时没法等，用 `tools/android-fgs-quota.sh` 把配额压到几十秒。
相关卡：[#409](https://github.com/hawkeye-xb/P-Pass/issues/409)、
[#397](https://github.com/hawkeye-xb/P-Pass/issues/397)、
[#414](https://github.com/hawkeye-xb/P-Pass/issues/414)、
[#411](https://github.com/hawkeye-xb/P-Pass/issues/411)。

## 用法

```bash
export ANDROID_SERIAL=RFCX1040SNE      # 连着多台设备时必填
just android-fgs-quota set 60          # 配额压到 60 秒
just android-fgs-quota status          # 打印当前实际生效值
just android-fgs-quota reset           # 恢复系统默认（做完实验必须跑）
```

包名默认 `com.hawkeyexb.ppass`，其他包用 `PPASS_PKG=<pkg>`。

脚本每一步都把值读回来核对，对不上就非零退出。重复执行 `set` 或 `reset`，结果不变。
`set` 做三件事：

1. **compat 开关**：targetSdk ≥ 35 时跳过。`FGS_INTRODUCE_TIME_LIMITS`（ChangeId 317799821，
   `enableSinceTargetSdk=35`）对这类包默认已开，`am compat enable` 会被系统拒绝（见下）。
   targetSdk < 35 时才执行 `am compat enable`。
2. **关闭 device_config 同步**：把 `set_sync_disabled_for_tests` 设为 `until_reboot`，防止服务端把值同步回来。
   原来的模式存在设备上的 `/data/local/tmp/ppass-fgs-quota.sync-mode`，`reset` 按它恢复。
3. **写配额**：`device_config put activity_manager data_sync_fgs_timeout_duration <毫秒>`，
   再从 `device_config get` 和 `dumpsys activity settings` 两处读回确认。后者读的是 AMS 实际在用的值。

`reset` 依次执行：`device_config delete`、`am compat reset`（仅 targetSdk < 35）、恢复 sync 模式。
`am compat reset` 即使没有 override 也会杀掉 App 进程（logcat：`Killing ... PlatformCompat overrides`），
所以 targetSdk ≥ 35 时不调它。
最后断言 AMS 生效值回到 `21600000`。

## 已核实的设备行为（三星 SM-S9210 / Android 15，2026-09-29）

- `device_config put` 立即生效：设 90000 后，FGS 从启动到 `FGS (dataSync) timed out` 共 89733ms
  （`am_foreground_service_timed_out` 事件里的数）。`device_config delete` 之后，AMS 立即回到 21600000。
- `am compat enable FGS_INTRODUCE_TIME_LIMITS com.hawkeyexb.ppass` 被拒，原文：
  `Cannot override 317799821 for com.hawkeyexb.ppass because the app's targetSdk (35) is above the change's targetSdk threshold (34)`。
- **App 在前台时不会到点，但前台运行的时间照样计入累计时长。**「切回前台清零」只在两种情况下发生：
  在前台时调用 `startForeground`；或者上次超时之后 App 又回过前台，下一次 `startForeground` 时清零。
  到点时刻取两者中较晚的一个：`本次启动 + (配额 − 累计)`，或者 `最后一次离开前台 + 配额`。
  依据是 AOSP android15-release 的 `ActiveServices.onFgsTimeout` / `getNextFgsStopTime`，下面的实测与它吻合（配额 60 秒）：
  - 前台跑了 77.4 秒，16:58:17.2 离开前台。16:58:59.6 在后台起 FGS，**17.5 秒后**（16:59:17.19）就到点了，
    正好是离开前台后 60 秒，而不是启动后 60 秒。
  - 累计已超过配额时，后台新起的 FGS 可能 `startForeground` 成功，**几毫秒后**就收到 `onTimeout`（实测 8ms）。
  所以要测一轮完整的后台配额，`set` 之后先打开 App **并在前台触发一次传输**，让计数清零，再按 HOME。
  如果此前没有超时过，光打开 App 不会清零，要在前台调到 `startForeground` 才会。
  做不到的话，就要把「离开前台 + 配额」当作到点时刻。
- 配额一旦在后台用完，后台再申请会被拒：`startForeground` 抛
  `ForegroundServiceStartNotAllowedException: Time limit already exhausted`。App 回到前台后可以重新申请。
- 后台能否申请 FGS，前提是 App 在电池白名单里（#411）。`status` 会打印是否在白名单。

## 复现实验步骤

1. `just android-fgs-quota set 60`。打开 App，在前台让它传一张（或者确认上次超时之后它回过前台），再按 HOME。
   这样计数才从零开始，原因见上一节。
2. 准备测试素材，总量要大到在配额内传不完。推到一个**已选中**的相册：

   ```bash
   adb push ppass-test-fgs-*.jpg /sdcard/DCIM/<已选中相册>/
   # adb push 进去的文件是 is_pending=1，App 看不见，必须逐条清掉：
   adb shell "content query --uri content://media/external/file --projection _id \
     --where \"_display_name like 'ppass-test-fgs-%'\""
   adb shell content update --uri content://media/external/file/<id> --bind is_pending:i:0
   ```

3. 取证：
   - `adb logcat -v threadtime -b main,system,crash,events`，关注这些行：
     `Background started FGS`、`am_foreground_service_start`、`FGS (dataSync) timed out`、
     `PPassFlow: foreground: onTimeout`、`Stop FGS timeout`、`Bringing down service`、`FATAL EXCEPTION`
   - 崩溃缓冲区：`adb logcat -b crash -d`
   - order 表（debug 包）：

     ```bash
     for f in backup-orders.db backup-orders.db-wal backup-orders.db-shm backup-orders.db-journal; do
       adb exec-out run-as com.hawkeyexb.ppass cat databases/$f > $f 2>/dev/null
     done
     sqlite3 backup-orders.db "select state,count(*) from orders group by 1"
     ```

   - 受阻原因：`adb exec-out run-as com.hawkeyexb.ppass cat files/flow-control.json`
4. 到点之后，先在后台触发一次（再推一张并清 `is_pending`），看被拒的路径；再切回前台，看续传。
5. 最后逐字节核对：手机源文件和桌面库文件的 `shasum -a 256` 清单用 `cmp` 比对。
6. **`just android-fgs-quota reset`**，保留它打印的 `status` 作为恢复证据。
