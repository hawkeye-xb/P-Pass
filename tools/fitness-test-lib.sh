# 适应度门禁自测的公共函数（被 tools/test-check-*.sh source）。
# 做法：在临时 git 仓库里放一份只含基线条目的登记表，先证明「基线必须绿」，
# 再逐个造违反、必须红且报出指定子串，还原后必须再绿。不碰真实代码树与真实登记表
# （真实登记表与真实代码的一致性由门禁本身在 just ci 里判）。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILED=0
ok()  { echo "  ok   $1"; }
bad() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; }

# new_repo <登记表文件名> <基线登记内容>：建临时仓库与登记表。
new_repo() {
  R="$TMP/repo"
  rm -rf "$R"; mkdir -p "$R/tools"
  printf '%s\n' "$2" >"$R/tools/$1"
  git -C "$R" init -q --template=
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
}
# put <相对路径> <内容>：写文件并 git add（门禁只看被跟踪的文件）。
put() {
  mkdir -p "$R/$(dirname "$1")"; printf '%s\n' "$2" >"$R/$1"; git -C "$R" add -f "$1"
}
unput() { git -C "$R" rm -qf "$1"; }
# run_check <检查脚本> → OUT / 退出码
run_check() { OUT="$(python3 "$REPO/tools/$1" --root "$R" 2>&1)"; }
expect_green() {
  if run_check "$CHECK"; then ok "$1"; else bad "$1（应绿，实际红）"; echo "$OUT" | head -8 | sed 's/^/       /'; fi
}
expect_red() {  # <描述> <必须出现的子串>
  if run_check "$CHECK"; then bad "$1（应红，实际绿）"; return; fi
  if printf '%s' "$OUT" | grep -qF -- "$2"; then ok "$1"; else bad "$1（红了但没有「$2」）"; echo "$OUT" | head -8 | sed 's/^/       /'; fi
}
finish() {
  if [ "$FAILED" -ne 0 ]; then echo "FAILED: $FAILED"; exit 1; fi
  echo "all ok"
}
