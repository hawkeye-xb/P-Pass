# P-Pass 本地 Android 环境前置（BUILD-01）
# 用法（source，导出 JAVA_HOME / ANDROID_NDK_HOME）：
#   source scripts/java-home.sh            # 仓根（justfile recipe 用 ../../）
#   source "$ROOT/scripts/java-home.sh"    # tools/*.sh
# 单独执行时只做检查并打印解析结果。
#
# 设计：
# - JDK 版本唯一真相 = 仓根 `.java-version`（CI 三处 setup-java 用
#   `java-version-file: .java-version` 读同一个文件——版本号只出现在这一处）。
# - 找不到时报「人话」+ 安装命令，而不是 gradle 的
#   `JAVA_HOME is set to an invalid directory` 或 AGP lint 吐裸版本号 `> 25.0.1`。
# - 为什么钉 21：iroh uniffi 绑定的 class 按 JDK 21 编译（major 65），
#   17 加载 live 剧本必 UnsupportedClassVersionError（e2e.yml 实测注释）。
# - 显式给定的 JAVA_HOME/ANDROID_NDK_HOME 一律尊重（CI 走 setup-java 即此路径）。

# ── JAVA_HOME ──────────────────────────────────────────────
_PPJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_PPJ_VER="$(tr -d '[:space:]' < "$_PPJ_ROOT/.java-version")"

# 候选必须实际是目标大版本——macOS `java_home -v` 在注册表缺该版本时会
# 静默回退返回最高版本（实测：只有 17 时 `-v 21` 返回 17 的 Home），
# 必须跑 java -version 校验，否则钉版本形同虚设。
_ppj_matches() {
  local p="$1" got
  [[ -x "$p/bin/java" ]] || return 1
  got="$("$p/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')"
  [[ "$got" == "$_PPJ_VER" ]]
}

if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  JAVA_HOME=""
  case "$(uname)" in
    Darwin)
      # 1) Homebrew keg-only 优先（openjdk@NN 不注册进 java_home；注册表里
      #    多 JDK 会触发 AGP JdkImageTransform 挂死，见 docs/NEXT.md 09-05）
      if command -v brew >/dev/null 2>&1; then
        _ppj_p="$(brew --prefix "openjdk@${_PPJ_VER}" 2>/dev/null || true)/libexec/openjdk.jdk/Contents/Home"
        _ppj_matches "$_ppj_p" && JAVA_HOME="$_ppj_p"
      fi
      # 2) 系统注册表（校验大版本后才可信）
      if [[ -z "$JAVA_HOME" ]]; then
        _ppj_p="$(/usr/libexec/java_home -v "$_PPJ_VER" 2>/dev/null || true)"
        [[ -n "$_ppj_p" ]] && _ppj_matches "$_ppj_p" && JAVA_HOME="$_ppj_p"
      fi
      ;;
    Linux)
      for _ppj_p in /usr/lib/jvm/*"$_PPJ_VER"* /opt/java/*"$_PPJ_VER"*; do
        _ppj_matches "$_ppj_p" && { JAVA_HOME="$_ppj_p"; break; }
      done
      ;;
  esac
  if [[ -z "$JAVA_HOME" ]]; then
    echo "✗ 需要 JDK ${_PPJ_VER}，本机没找到（版本唯一真相：仓根 .java-version，与 CI 同一处）。" >&2
    echo "  macOS: brew install openjdk@${_PPJ_VER}" >&2
    echo "  Linux: sudo apt-get install openjdk-${_PPJ_VER}-jdk" >&2
    return 1 2>/dev/null || exit 1
  fi
fi
export JAVA_HOME

# ── ANDROID_NDK_HOME ──────────────────────────────────────
# REBUILD-01 起 gradle 配置期就要求它（buildIrohBlobsProviderBridge）；
# 本地从 apps/android/local.properties 的 sdk.dir 解析，取最新 NDK。
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "${ANDROID_NDK_HOME}" ]]; then
  ANDROID_NDK_HOME=""
  _ppj_lp="$_PPJ_ROOT/apps/android/local.properties"
  _ppj_sdk=""
  if [[ -f "$_ppj_lp" ]]; then
    _ppj_sdk="$(grep -E '^sdk\.dir=' "$_ppj_lp" | cut -d= -f2- || true)"
  fi
  [[ -z "$_ppj_sdk" && -n "${ANDROID_HOME:-}" ]] && _ppj_sdk="$ANDROID_HOME"
  if [[ -n "$_ppj_sdk" && -d "$_ppj_sdk/ndk" ]]; then
    _ppj_ndk="$(ls "$_ppj_sdk/ndk" 2>/dev/null | sort -V | tail -1 || true)"
    [[ -n "$_ppj_ndk" && -d "$_ppj_sdk/ndk/$_ppj_ndk" ]] && \
      ANDROID_NDK_HOME="$_ppj_sdk/ndk/$_ppj_ndk"
  fi
  if [[ -z "$ANDROID_NDK_HOME" ]]; then
    echo "✗ 需要 Android NDK，本机没找到。" >&2
    echo "  装 Android SDK 的 ndk 组件（Android Studio → SDK Manager → NDK），" >&2
    echo "  并确认 apps/android/local.properties 里 sdk.dir 指向它；或手动 export ANDROID_NDK_HOME。" >&2
    return 1 2>/dev/null || exit 1
  fi
fi
export ANDROID_NDK_HOME

# 单独执行（非 source）：打印解析结果
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "$JAVA_HOME"
fi
