#!/usr/bin/env bash
# 本机测试清场：让下一次「安装」真正从白板开始——停掉 launchd 常驻服务、
# kill 残留进程、卸载 App、清空数据目录（身份/配对/索引全丢，重装即重建）。
# 治的是 A 类孤儿（测试脚本泄漏的裸 daemon）+ B 类孤儿（launchd 钉着旧
# 路径的常驻服务）同款病，见 docs/product/2026-08-04-experience-gaps.md §三之二。
#
# Usage: tools/reset-local.sh [-y|--yes]
#   -y/--yes  跳过确认提示（脚本化场景用）
#
# 不可逆：会删 /Applications/P-Pass.app、~/Library/Application Support/P-Pass
# （只是 config.toml 指针）**以及 config.toml 里 data_dir 指向的照片库
# 目录本身**（身份 identity.key、配对白名单、index.sqlite、缩略图、
# blob、originals 原图全部真正存在这个目录的 .ppf/ 子目录里——只删指针
# 不删这里等于没清场，daemon 重装后指回同一个照片库会发现身份还在）。
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: 仅支持 macOS（LaunchAgent/Application Support 路径是 macOS 专属）" >&2
  exit 1
fi

AGENT_LABEL="com.p-pass.daemon"
PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"
APP="/Applications/P-Pass.app"
CONFIG_DIR="$HOME/Library/Application Support/P-Pass"
LOG_OUT="$HOME/Library/Logs/p-pass-daemon.log"
LOG_ERR="$HOME/Library/Logs/p-pass-daemon.err"

# 2026-08-17：CONFIG_DIR 只是个指针（config.toml 里的 data_dir 字段），
# 真正的身份/配对白名单/索引/缩略图/blob 全在用户选的照片库文件夹的
# .ppf/ 子目录里——只删 CONFIG_DIR 只是清了指针，daemon 重装后指回
# 同一个照片库文件夹会发现 .ppf/identity.key 还在，配对状态不会真的
# 归零，不是干净的白板。这里在删 CONFIG_DIR 之前先把 data_dir 读出来。
PHOTO_LIBRARY_DIR=""
if [ -f "$CONFIG_DIR/config.toml" ]; then
  # 注意：macOS 自带 BSD sed 的 ERE 不认 \s（GNU 扩展），必须用
  # [[:space:]] 这种 POSIX 写法，否则匹配不上、PHOTO_LIBRARY_DIR 悄悄
  # 留空——2026-08-17 实测踩过一次，照片库目录（真正的身份/配对/索引
  # 所在地）没删掉，脚本还汇报"清场成功"，是本脚本的真事故不是假设。
  PHOTO_LIBRARY_DIR="$(sed -nE 's/^data_dir[[:space:]]*=[[:space:]]*"(.*)"[[:space:]]*$/\1/p' "$CONFIG_DIR/config.toml" | head -1)"
fi

YES=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    *) echo "usage: tools/reset-local.sh [-y|--yes]" >&2; exit 1 ;;
  esac
done

if [ "$YES" -ne 1 ]; then
  # 注意：macOS 自带 bash 3.2（GPLv3 avoidance，苹果一直没升级）解析
  # $VAR 紧跟多字节 UTF-8 字符（比如中文标点）在 set -u 下有真实 bug——
  # 会把变量名跟后面字符的字节片段混着解析成一个不存在的变量名，报
  # "unbound variable"（2026-08-17 实测复现，`bash -c 'set -u; FOO=x;
  # echo "$FOO（"'` 直接炸）。全脚本 $VAR 后紧跟中文标点的地方一律用
  # ${VAR} 花括号显式定界，不能偷懒省略。
  echo "将执行不可逆清场：删 ${APP}、${CONFIG_DIR}（config.toml 指针）、${PLIST}"
  echo "以及真正存身份/配对/索引的照片库目录：${PHOTO_LIBRARY_DIR:-<config.toml 未记录，跳过>}"
  read -r -p "确认继续？输入 yes 继续，其它任意键取消: " CONFIRM
  [ "$CONFIRM" = "yes" ] || { echo "已取消。"; exit 1; }
fi

echo "== 1. 读 plist 记录的常驻服务二进制路径（清场前存证）=="
DAEMON_BIN=""
if [ -f "$PLIST" ]; then
  DAEMON_BIN="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST" 2>/dev/null || true)"
  echo "  ${AGENT_LABEL} -> ${DAEMON_BIN:-<读不到>}"
else
  echo "  未注册 ${AGENT_LABEL}（跳过）"
fi

echo "== 2. launchctl bootout（先停止自复活，再动文件/进程）=="
UID_N="$(id -u)"
launchctl bootout "gui/${UID_N}/${AGENT_LABEL}" 2>/dev/null \
  && echo "  bootout 完成" \
  || echo "  未注册/已停（正常）"
rm -f "$PLIST" && echo "  已删 $PLIST" || true

echo "== 3. kill 残留进程（A 类孤儿：裸跑的 daemon/testclient + 桌面壳）=="
if [ -n "$DAEMON_BIN" ]; then
  pkill -f "$DAEMON_BIN" 2>/dev/null && echo "  已 kill $DAEMON_BIN" || true
fi
pkill -f 'ppf-daemon' 2>/dev/null && echo "  已 kill ppf-daemon" || true
# 2026-08-17：真事故实锤——`pnpm tauri dev` 是从 apps/desktop/src-tauri
# 这个 cwd 启动子进程的，argv 里存的是相对路径 `target/debug/p-pass-desktop`
# （没有前导 `/`）。下面这几条 pattern 原来写的是 `/target/(debug|release)/...`
# （带前导斜杠），`pkill -f`/`pgrep -f` 是子串匹配不是锚定匹配，但相对路径
# 字符串里压根没有这个前导 `/` 子串，导致这几条从来没匹配上过——`pnpm
# tauri dev` 起的桌面壳进程在「清场」全程存活，验证步骤（当年同一个
# pattern 写了两遍）也因为同款 bug 谎报「✅ 无残留进程」。后果：桌面壳
# 网页层的 Svelte 内存态（比如照片墙数组）跨越整次数据清场纹丝不动，
# daemon/sqlite 真清空了，界面却因为进程根本没重启而继续显示清场前的
# 缩略图——「清数据清得不够彻底」的假象根源在这里，不在数据层。
# 反证：`pgrep -fl '/target/(debug|release)/p-pass-desktop'` 在真实
# `pnpm tauri dev` 会话下返回空（exit 1），去掉前导 `/` 后立刻能匹配到。
pkill -f 'target/(debug|release)/(daemon|testclient)' 2>/dev/null && echo "  已 kill 开发构建 daemon/testclient" || true
pkill -f 'P-Pass.app/Contents/MacOS/p-pass-desktop' 2>/dev/null && echo "  已 kill 桌面壳" || true
pkill -f 'target/(debug|release)/p-pass-desktop' 2>/dev/null && echo "  已 kill 开发构建桌面壳（pnpm tauri dev）" || true
sleep 1

echo "== 4. 卸载 App =="
if [ -d "$APP" ]; then rm -rf "$APP" && echo "  已删 $APP"; else echo "  未安装（跳过）"; fi

echo "== 5. 清空数据（config 指针 + 真正的照片库 .ppf 身份/配对/索引）=="
if [ -d "$CONFIG_DIR" ]; then rm -rf "$CONFIG_DIR" && echo "  已删 $CONFIG_DIR"; else echo "  config 目录不存在（跳过）"; fi
if [ -n "$PHOTO_LIBRARY_DIR" ] && [ -d "$PHOTO_LIBRARY_DIR" ]; then
  rm -rf "$PHOTO_LIBRARY_DIR" && echo "  已删照片库 ${PHOTO_LIBRARY_DIR}（含 .ppf 身份/配对/索引/缩略图/blob 与 originals 原图）"
else
  echo "  照片库目录不存在/未记录（跳过）"
fi
rm -f "$LOG_OUT" "$LOG_ERR"

echo "== 6. 验证清场 =="
FAIL=0
if REMAIN=$(pgrep -fl 'ppf-daemon|target/(debug|release)/(daemon|testclient|p-pass-desktop)|P-Pass\.app/Contents/MacOS/p-pass-desktop' 2>/dev/null); then
  echo "  ⚠️ 仍有残留进程："
  echo "$REMAIN"
  FAIL=1
else
  echo "  ✅ 无残留进程"
fi
if launchctl print "gui/${UID_N}/${AGENT_LABEL}" >/dev/null 2>&1; then
  echo "  ⚠️ launchd 仍注册着 ${AGENT_LABEL}"
  FAIL=1
else
  echo "  ✅ launchd 无 ${AGENT_LABEL} 条目"
fi
[ -d "$APP" ] && { echo "  ⚠️ $APP 仍存在"; FAIL=1; } || echo "  ✅ App 已卸载"
[ -d "$CONFIG_DIR" ] && { echo "  ⚠️ $CONFIG_DIR 仍存在"; FAIL=1; } || echo "  ✅ config 指针已清空"
if [ -n "$PHOTO_LIBRARY_DIR" ] && [ -d "$PHOTO_LIBRARY_DIR" ]; then
  echo "  ⚠️ 照片库 $PHOTO_LIBRARY_DIR 仍存在"
  FAIL=1
else
  echo "  ✅ 照片库（身份/配对/索引）已清空"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "清场未完全成功，见上面 ⚠️ 项。" >&2
  exit 1
fi
echo "== 白板已就位，可以开始安装/测试 =="
