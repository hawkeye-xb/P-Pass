# apps/android

Android Gradle project (T-050..T-056): iroh-ffi + generated proto types +
backup pipeline (MediaStore watermark) + timeline browsing.

---

Android Gradle 工程（T-050~T-056）：iroh-ffi + proto 生成类型 +
备份管道（MediaStore 水位）+ 时间线浏览。

## 构建前提

- JDK 21、Android SDK（compileSdk 35）、`ANDROID_NDK_HOME` 指向 NDK、
  `rustup target add aarch64-linux-android`、`local.properties` 写 `sdk.dir`。
- `:app:buildIrohBlobsProviderBridge` 经 bash 跑 `tools/build-android-iroh-blobs-bridge.sh`
  编 `libtransport.so` 并生成 Kotlin 绑定。

### Windows

- 需要 Git for Windows：Gradle 会从 `git --exec-path` 找到它自带的 `bash.exe`（不用 WSL 的
  `bash`）；Git 装在别处时设 `PPASS_BASH` 指向 bash.exe。
- 仓库里没有 `gradlew.bat`，在 Git Bash 里运行：`bash ./gradlew :app:testDebugUnitTest`。
