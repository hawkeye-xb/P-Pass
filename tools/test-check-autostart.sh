#!/usr/bin/env bash
# tools/check-autostart.py 的自测：未登记的自启调用点必须红，守卫符号消失必须红，还原必须绿。
set -uo pipefail
. "$(dirname "$0")/fitness-test-lib.sh"
CHECK=check-autostart.py
new_repo autostart-registry.txt 'autostart|crates/base/src/host.rs|guard:user_stopped|基线：先判 user_stopped'

echo "尊重用户停服务门禁自测"
put crates/base/src/host.rs 'pub fn user_stopped(state: &std::path::Path) -> bool { state.exists() }
fn boot(s: &std::path::Path) { if user_stopped(s) { return; } Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
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
put apps/desktop/src-tauri/windows/installer-hooks.nsh 'Function F
nsExec::ExecToLog "$PS" -Command "Register-ScheduledTask -TaskName x"'
expect_red "NSIS 新增 Register-ScheduledTask（未登记）" "installer-hooks.nsh"
unput apps/desktop/src-tauri/windows/installer-hooks.nsh
put apps/ios/P/Bg.swift 'try BGTaskScheduler.shared.submit(request)'
expect_red "iOS 新增 BGTaskScheduler.submit" "apps/ios/P/Bg.swift"
unput apps/ios/P/Bg.swift; expect_green "还原：全部"

# 守卫符号被改名 / 删除，或退化为恒返回字面量布尔桩：必须判红
put crates/base/src/host.rs 'fn boot() { Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_red "守卫函数被删（只剩拉起调用）" "user_stopped"
put crates/base/src/host.rs 'pub fn user_stopped() -> bool { false }
fn boot() { if user_stopped() { return; } Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_red "守卫函数退化为恒返回 false 空壳（T5 式绕过拦截）" "退化为恒返回布尔字面量"
put apps/android/app/src/main/java/a/Guard.java 'class Guard { boolean user_stopped() { return false; } }'
expect_red "Java 守卫方法退化为恒返回 false 空壳 → 判红" "退化为恒返回布尔字面量"
unput apps/android/app/src/main/java/a/Guard.java
put apps/android/app/src/main/java/a/KtGuard.kt 'fun user_stopped(state: java.io.File): Boolean = false || state.exists()'
put crates/base/src/host.rs 'pub fn user_stopped(state: &std::path::Path) -> bool { state.exists() }
fn boot(s: &std::path::Path) { if user_stopped(s) { return; } Command::new("launchctl").args(["bootstrap", "gui/501"]); }'
expect_green "Kotlin 完整复合布尔表达式（= false || state.exists()）不误判 + 还原真实守卫"
unput apps/android/app/src/main/java/a/KtGuard.kt

# 反证：在共享库 fitness_lib.py 中违规 import 业务包必须判红
mkdir -p "$TMP/mut_tools"
cp "$REPO/tools/check-autostart.py" "$REPO/tools/fitness_lib.py" "$TMP/mut_tools/"
printf '\nimport minippass_fake_pkg\n' >>"$TMP/mut_tools/fitness_lib.py"
if python3 -I "$TMP/mut_tools/check-autostart.py" --root "$R" >/dev/null 2>&1; then
  bad "fitness_lib.py 导入业务包仍通过"
else
  ok "反证：fitness_lib.py 导入业务模块时 AST 自检判红"
fi

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
