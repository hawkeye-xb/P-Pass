# M-pkg：桌面包里的 C 编解码库合规（版本不低于下限、没有禁用库、依赖只在包内或系统路径）。
# 对象：E3_MAC_APP（默认本机已装的 ~/Applications/P-Pass.app）。判定复用 tools/check-codec-libs.sh。
# 反证：把包里的库目录复制一份、塞进一个禁用库名（libx265）⇒ 必须判红。
DESC="桌面包编解码库合规（check-codec-libs）；反证塞入禁用库"
COUNTER=on

setup() { [ -d "$MAC_APP" ] || { echo "没有可检查的包：$MAC_APP"; return 77; }; }

scan() { # <目录或 .app>
  defaults read "$MAC_APP/Contents/Info.plist" CFBundleShortVersionString >"$OUT/app-version.txt" 2>&1
  "$REPO_ROOT/tools/check-codec-libs.sh" macos "$1" >"$OUT/check-codec-libs.txt" 2>&1
  echo $? >"$OUT/exit.txt"
}

act() { scan "$MAC_APP"; }

judge() {
  local d="$1"
  echo "  INFO  包版本 $(cat "$d/app-version.txt" 2>/dev/null)"
  check "check-codec-libs 退出 0" eq_file "$d/exit.txt" 0
  verdict
}

counter() {
  local t="$E3_STATE/pkg-counter"
  rm -rf "$t"
  mkdir -p "$t"
  cp -R "$MAC_APP/Contents/Helpers/ppf-daemon.app/Contents/MacOS/lib" "$t/lib"
  cp "$(ls "$t"/lib/libde265*.dylib | head -1)" "$t/lib/libx265.dylib"
  scan "$t"
}
