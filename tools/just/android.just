# Android 单测、真机测试与协议联调配方

# Android unit tests (proto golden drift check included)
android-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ justfile_directory() }}/tools/java-home.sh"
    cd "{{ justfile_directory() }}/apps/android"
    ./gradlew -q :app:testDebugUnitTest

# #1820：Android 设备测试（instrumented），跑完保留 App 与数据——配对、范围、设置不丢。
# 默认 Gradle 跑完会卸载测试 APK 和 App；leaveApksInstalledAfterRun=true 让两者留在设备上。
# 只改设备测试的跑法，不碰 just android-test（JVM 单测）的语义。日常预览走 `just dev`，用 `install -r` 不卸载。
# 设备/多机选择、额外 Gradle 参数原样转交：just android-instrumented -Pfoo=bar。
android-instrumented *args:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ justfile_directory() }}/tools/java-home.sh"
    cd "{{ justfile_directory() }}/apps/android"
    ./gradlew -q :app:connectedDebugAndroidTest \
      -Pandroid.injected.androidTest.leaveApksInstalledAfterRun=true {{args}}

# T-051 live check: Kotlin iroh-ffi client speaks hello to a real daemon
android-hello:
  tools/android-hello.sh

# T-052 live check: full pairing flow (Kotlin phone + IPC owner confirm)
android-pair:
  tools/android-pair.sh

# Android 15 dataSync FGS 配额压缩（#409 #397 #414）：set <秒> / status / reset。
# 多台设备时先 export ANDROID_SERIAL。用法与判据见 docs/runbook/android-fgs-quota.md。
android-fgs-quota *args:
  bash tools/android-fgs-quota.sh {{args}}
