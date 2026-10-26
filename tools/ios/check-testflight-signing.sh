#!/usr/bin/env bash
# TestFlight 签名形状门禁：CI 运行时绝不新建证书。
#
# 背景：归档带 -allowProvisioningUpdates + API 密钥时，全新 runner 的钥匙串里没有证书，Xcode 就在归档时
# 新建一张 Apple Development 证书，一次一张，累积到账号上限后归档失败（run 40298231858）。
# 规则（对 tools/ios/testflight-upload.sh 与 .github/** 做文字级检查）：
#   1. 上传脚本里的 `xcodebuild archive` 命令（含反斜杠续行）必须带 CODE_SIGNING_ALLOWED=NO，
#      且不许带 -allowProvisioningUpdates / -allowProvisioningDeviceRegistration / -authenticationKey* /
#      任何 *SIGN_ARGS 参数数组（签名参数只许出现在导出那一步）。
#   2. 上传脚本里的 `xcodebuild -exportArchive` 命令必须带 EXPORT_SIGN_ARGS（云签名 + API 密钥）。
#   3. .github/** 里不许直接写 `xcodebuild archive`：归档只走上传脚本这一处。
#
#   tools/ios/check-testflight-signing.sh                # 检查仓库
#   tools/ios/check-testflight-signing.sh --self-test    # 反证：几种回退写法都必须被拦
#   tools/ios/check-testflight-signing.sh <上传脚本> <.github 目录>   # 检查指定文件（自测用）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# 打印脚本里某条 xcodebuild 命令（把反斜杠续行拼成一行）。$1=文件 $2=识别该命令首行的 ERE。
command_block() {
  awk -v pat="$2" '
    !inblk && $0 ~ pat { inblk = 1; buf = "" }
    inblk {
      line = $0
      cont = (line ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "", line)
      buf = buf " " line
      if (!cont) { print buf; inblk = 0 }
    }
  ' "$1"
}

check() { # <上传脚本> <.github 目录>；违规打印到 stderr，返回 1
  local script="$1" gh="$2" fail=0 archive export n
  [ -f "$script" ] || { echo "✗ 找不到 $script" >&2; return 1; }

  archive=$(command_block "$script" '^[[:space:]]*xcodebuild[[:space:]]+archive([[:space:]]|$)')
  n=$(printf '%s' "$archive" | grep -c . || true)
  if [ "$n" != 1 ]; then
    echo "✗ ${script#"$ROOT"/}：应恰好有 1 条 xcodebuild archive，实际 ${n} 条" >&2; fail=1
  else
    if ! grep -qE '(^|[[:space:]])CODE_SIGNING_ALLOWED=NO([[:space:]]|$)' <<<"$archive"; then
      echo "✗ 归档没关签名（缺 CODE_SIGNING_ALLOWED=NO）：$archive" >&2; fail=1
    fi
    if grep -qE -- '-allowProvisioning(Updates|DeviceRegistration)|-authenticationKey|SIGN_ARGS' <<<"$archive"; then
      echo "✗ 归档带了签名更新 / API 密钥参数（会在 runner 上新建证书）：$archive" >&2; fail=1
    fi
  fi

  export=$(command_block "$script" '^[[:space:]]*(if[[:space:]]+(![[:space:]]+)?)?xcodebuild[[:space:]]+-exportArchive')
  n=$(printf '%s' "$export" | grep -c . || true)
  if [ "$n" != 1 ]; then
    echo "✗ ${script#"$ROOT"/}：应恰好有 1 条 xcodebuild -exportArchive，实际 ${n} 条" >&2; fail=1
  elif ! grep -q 'EXPORT_SIGN_ARGS' <<<"$export"; then
    echo "✗ 导出没带 EXPORT_SIGN_ARGS（云签名 + API 密钥）：${export:-<没找到 xcodebuild -exportArchive>}" >&2; fail=1
  fi

  if [ -d "$gh" ]; then
    local hits
    hits=$(grep -rnE 'xcodebuild[[:space:]]+archive([[:space:]]|$)' "$gh" || true)
    if [ -n "$hits" ]; then
      echo "✗ .github 里直接写了 xcodebuild archive（归档只许走 tools/ios/testflight-upload.sh）：" >&2
      printf '%s\n' "$hits" >&2; fail=1
    fi
  fi
  return "$fail"
}

if [ "${1:-}" = "--self-test" ]; then
  SRC="$ROOT/tools/ios/testflight-upload.sh"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP/gh"
  check "$SRC" "$TMP/gh" || { echo "✗ 自测失败：当前上传脚本本身不过门禁" >&2; exit 1; }

  expect_red() { # <名字> <脚本> [gh 目录]
    if check "$2" "${3:-$TMP/gh}" 2>/dev/null; then echo "✗ 自测失败：「$1」没被拦住" >&2; exit 1; fi
    echo "  红（符合预期）：$1"
  }
  # A. 去掉关签名
  sed 's/CODE_SIGNING_ALLOWED=NO//' "$SRC" > "$TMP/a.sh"
  expect_red "归档去掉 CODE_SIGNING_ALLOWED=NO" "$TMP/a.sh"
  # B. 归档加回 -allowProvisioningUpdates
  sed 's/CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_ALLOWED=NO -allowProvisioningUpdates/' "$SRC" > "$TMP/b.sh"
  expect_red "归档加 -allowProvisioningUpdates" "$TMP/b.sh"
  # C. 旧写法：归档用签名参数数组（#348 的原样）
  sed 's/CODE_SIGNING_ALLOWED=NO/"${SIGN_ARGS[@]}"/' "$SRC" > "$TMP/c.sh"
  expect_red "归档用 \"\${SIGN_ARGS[@]}\"（旧写法）" "$TMP/c.sh"
  # D. 归档用导出的参数数组
  sed 's/CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_ALLOWED=NO "${EXPORT_SIGN_ARGS[@]}"/' "$SRC" > "$TMP/d.sh"
  expect_red "归档混入 EXPORT_SIGN_ARGS" "$TMP/d.sh"
  # E. 导出丢了云签名参数
  sed 's/"\${EXPORT_SIGN_ARGS\[@\]}"//' "$SRC" > "$TMP/e.sh"
  expect_red "导出不带 EXPORT_SIGN_ARGS" "$TMP/e.sh"
  # F. workflow 里另起一条归档
  mkdir -p "$TMP/gh2/workflows"
  printf 'jobs:\n  x:\n    steps:\n      - run: xcodebuild archive -scheme PPass -allowProvisioningUpdates\n' > "$TMP/gh2/workflows/x.yml"
  expect_red ".github 里直接 xcodebuild archive" "$SRC" "$TMP/gh2"
  echo "ok: 自测通过（当前脚本放行，6 种回退写法全部被拦）"
  exit 0
fi

SCRIPT="${1:-$ROOT/tools/ios/testflight-upload.sh}"
GH="${2:-$ROOT/.github}"
check "$SCRIPT" "$GH"
echo "ok: TestFlight 归档无签名（CODE_SIGNING_ALLOWED=NO、无签名更新参数），签名只在导出时走云签名"
