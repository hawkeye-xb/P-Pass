#!/usr/bin/env bash
# tools/check-autostart.py 的自测：未登记的自启调用点必须红，守卫符号消失必须红，还原必须绿。
set -uo pipefail
. "$(dirname "$0")/fitness-test-lib.sh"
CHECK=check-autostart.py
new_repo autostart-registry.txt 'autostart|crates/base/src/host.rs|guard:user_stopped|基线：先判 user_stopped'

echo "尊重用户停服务门禁自测"
put crates/base/src/host.rs 'pub fn user_stopped() -> bool { false }
fn boot() { if user_stopped() { return; } Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_green "基线：已登记且守卫符号存在"

put apps/android/app/src/main/java/a/New.kt 'fun go(c: Context) { WorkManager.getInstance(c).enqueueUniqueWork("n", p, req) }'
expect_red "Android 新增 WorkManager 入队（未登记）" "autostart|apps/android/app/src/main/java/a/New.kt"
unput apps/android/app/src/main/java/a/New.kt; expect_green "还原：Android"
put apps/android/app/src/main/java/a/Fgs.kt 'ContextCompat.startForegroundService(app, intent)'
expect_red "Android 新增 startForegroundService" "a/Fgs.kt"
unput apps/android/app/src/main/java/a/Fgs.kt
put apps/android/app/src/main/AndroidManifest.xml '<action android:name="android.intent.action.BOOT_COMPLETED" />'
expect_red "Manifest 新增 BOOT_COMPLETED" "AndroidManifest.xml"
unput apps/android/app/src/main/AndroidManifest.xml
put crates/platform/src/windows.rs 'unsafe { StartServiceW(h, None) };'
expect_red "Windows 新增 StartServiceW" "crates/platform/src/windows.rs"
unput crates/platform/src/windows.rs
put apps/ios/P/Bg.swift 'try BGTaskScheduler.shared.submit(request)'
expect_red "iOS 新增 BGTaskScheduler.submit" "apps/ios/P/Bg.swift"
unput apps/ios/P/Bg.swift; expect_green "还原：全部"

# 守卫符号被改名 / 删除：登记还在、代码里没了 → 红
put crates/base/src/host.rs 'fn boot() { Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_red "守卫函数被删（只剩拉起调用）" "user_stopped"
put crates/base/src/host.rs 'pub fn user_stopped() -> bool { false }
fn boot() { if user_stopped() { return; } Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_green "还原：守卫"

# 保护字段不合规 / 登记缺说明
cp "$R/tools/autostart-registry.txt" "$TMP/base.txt"
printf 'autostart|crates/base/src/host.rs|随便写|x\n' >"$R/tools/autostart-registry.txt"
expect_red "保护字段格式不对" "保护字段必须是"
printf 'autostart|crates/base/src/host.rs|guard:user_stopped|\n' >"$R/tools/autostart-registry.txt"
expect_red "登记缺说明" "说明不许留空"
cp "$TMP/base.txt" "$R/tools/autostart-registry.txt"
expect_green "还原：登记表"

# 注释里提到不算
put crates/base/src/doc.rs '// 不要在这里 launchctl kickstart，见 #957
fn f() {}'
expect_green "注释不算"
finish
