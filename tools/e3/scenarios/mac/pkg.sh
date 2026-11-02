# M-pkg：桌面包里的 C 编解码库合规（版本不低于下限、没有禁用库、依赖只在包内或系统路径）。
# 对象：发布包（E3_MAC_PKG_APP 指定，默认 GitHub Release 上最新 v* tag 的 macOS 包）。本地出的候选包
# 编解码库来自 Homebrew（发布流水线另编固定版本，见 tools/build-codecs-macos.sh），不代表发布包，不拿它判。
# 判定复用 tools/check-codec-libs.sh。
# 反证：把包里的库目录复制一份、塞进一个禁用库名（libx265）⇒ 必须判红。
DESC="桌面包编解码库合规（check-codec-libs）；反证塞入禁用库"
COUNTER=on

source "$E3_LIB/mac-install.sh"

setup() {
  local tag
  PKG_APP="${E3_MAC_PKG_APP:-}"
  if [ -z "$PKG_APP" ]; then
    tag=$(gh release list -R "${E3_GH_REPO:-hawkeye-xb/P-Pass}" --limit 30 --json tagName -q '.[].tagName' | grep -m1 '^v[0-9]')
    PKG_APP=$(mac_fetch_release "$tag") || { echo "下载 $tag 失败"; return 1; }
  fi
  [ -d "$PKG_APP" ] || { echo "没有可检查的包：$PKG_APP"; return 1; }
}

scan() { # <目录或 .app>
  defaults read "$PKG_APP/Contents/Info.plist" CFBundleShortVersionString >"$OUT/app-version.txt" 2>&1
  "$REPO_ROOT/tools/check-codec-libs.sh" macos "$1" >"$OUT/check-codec-libs.txt" 2>&1
  echo $? >"$OUT/exit.txt"
}

act() { scan "$PKG_APP"; }

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
  cp -R "$PKG_APP/Contents/Helpers/ppf-daemon.app/Contents/MacOS/lib" "$t/lib"
  cp "$(ls "$t"/lib/libde265*.dylib | head -1)" "$t/lib/libx265.dylib"
  scan "$t"
}
