#!/usr/bin/env bash
# CI 检查 → 本地命令对照表（tools/flow/ci-local-map.{tsv,py}）与本机执行器（tools/flow/owner-ci-local.sh）
# 的判据测试。每条「红」都配一条只去掉触发条件的「绿」作反证。
#
#   tools/flow/ci-local-map.test.sh  （just ci-local-map-check / just ci-docs / just ci 都跑）
#
# 放在 tools/flow/ 而不是 tools/test-ci-*：后者在 .github/core-paths.txt 里是核心路径（CI 判据的测试）。
#
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${SRC}/tools/flow/ci-local-map.py"
MAP="${SRC}/tools/flow/ci-local-map.tsv"
WF="${SRC}/.github/workflows"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { # check <描述> <命令...>
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
map_check() { python3 "$PY" check "$@" >"${TMP}/out" 2>&1; }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "${TMP}/tpl"
export GIT_TEMPLATE_DIR="${TMP}/tpl"
git config --global user.name "Map Test"
git config --global user.email "map-test@example.invalid"
git config --global init.defaultBranch main
export PPASS_HEAVY_LOCK="${TMP}/heavy.lock"

echo "── 1. 覆盖检查：真实 workflow + 真实对照表"
map_check
check "全映射 → 绿（CI-LOCAL-MAP OK）" grep -q '^CI-LOCAL-MAP OK [0-9]* jobs$' "${TMP}/out"
# 三类今天漏过的检查必须在对照表里有本机步骤
check "iOS App 测试与 TransportFFITests 都在 ci-ios.yml:ios 的本机步骤里" bash -c \
  'awk -F"\t" "\$1==\"ci-ios.yml\" && \$2==\"ios\" && \$3==\"mac\"" "$1" | grep -q "tools/ios/test.sh" &&
   awk -F"\t" "\$1==\"ci-ios.yml\" && \$2==\"ios\" && \$3==\"mac\"" "$1" | grep -q "tools/ios/test-transport-ffi.sh"' _ "$MAP"
check "Mac 与 Windows 的 Rust 测试都先构建 ppf-decoder" bash -c \
  'awk -F"\t" "\$2==\"test\" && \$3==\"mac\"" "$1" | grep -q "@PPF_DECODER@ && cargo nextest" &&
   awk -F"\t" "\$2==\"test-windows\" && \$3==\"win\"" "$1" | grep -q "@PPF_DECODER@ && cargo nextest"' _ "$MAP"

echo "── 2. 删一条映射 → 红（反证）"
grep -v $'^ci-ios.yml\tios\t' "$MAP" >"${TMP}/map-missing.tsv"
map_check --map "${TMP}/map-missing.tsv"
rc=$?
check "删掉 ci-ios.yml:ios 的全部行 → 退出 1" test "$rc" -eq 1
check "红的原因点名 ci-ios.yml 的 job「ios」" grep -q 'ci-ios.yml 的 job「ios」没有映射' "${TMP}/out"
map_check --map "$MAP"
check "反证：还原 → 绿" grep -q '^CI-LOCAL-MAP OK' "${TMP}/out"

echo "── 3. workflow 新增 job 而对照表没跟上 → 红"
cp -R "$WF" "${TMP}/wf"
cat >>"${TMP}/wf/ci-dco.yml" <<'EOF'
  brand-new-check:
    runs-on: ubuntu-latest
    steps:
      - run: echo new
EOF
map_check --workflows "${TMP}/wf"
rc=$?
check "新 job「brand-new-check」没映射 → 退出 1" bash -c '[ "$1" -eq 1 ] && grep -q "brand-new-check" "$2"' _ "$rc" "${TMP}/out"
printf 'ci-dco.yml\tbrand-new-check\tmac\talways\tnew\techo new\n' >"${TMP}/map-new.tsv"
cat "$MAP" >>"${TMP}/map-new.tsv"
map_check --workflows "${TMP}/wf" --map "${TMP}/map-new.tsv"
check "反证：补上映射 → 绿" grep -q '^CI-LOCAL-MAP OK' "${TMP}/out"
cp "${TMP}/wf/e2e.yml" "${TMP}/wf/ci-zzz.yml"
map_check --workflows "${TMP}/wf" --map "${TMP}/map-new.tsv"
check "新增整个 ci-*.yml workflow 也会被发现" bash -c '[ "$1" -ne 0 ] && grep -q "ci-zzz.yml 的 job" "$2"' _ "$?" "${TMP}/out"

echo "── 4. 映射指向不存在的 job / 缺理由 / gate 写错 → 红"
cp "$MAP" "${TMP}/map-stale.tsv"
printf 'ci-rust.yml\tgone-job\tmac\tlane\tx\techo x\n' >>"${TMP}/map-stale.tsv"
map_check --map "${TMP}/map-stale.tsv"
check "指向已删的 job → 红" bash -c '[ "$1" -eq 1 ] && grep -q "没有 job「gone-job」" "$2"' _ "$?" "${TMP}/out"
cp "$MAP" "${TMP}/map-noreason.tsv"
printf 'ci-dco.yml\tdco\tci-only\t-\tx\t\n' >>"${TMP}/map-noreason.tsv"
map_check --map "${TMP}/map-noreason.tsv"
check "ci-only 不写理由 → 红" bash -c '[ "$1" -eq 1 ] && grep -q "最后一列为空" "$2"' _ "$?" "${TMP}/out"
cp "$MAP" "${TMP}/map-gate.tsv"
printf 'ci-dco.yml\tdco\tmac\tsometimes\tx\techo x\n' >>"${TMP}/map-gate.tsv"
map_check --map "${TMP}/map-gate.tsv"
check "gate 写成看不懂的值 → 红" bash -c '[ "$1" -eq 1 ] && grep -q "gate 只能是" "$2"' _ "$?" "${TMP}/out"
printf 'ci-dco.yml\tdco\tmac\talways\n' >"${TMP}/map-cols.tsv"
map_check --map "${TMP}/map-cols.tsv"
check "列数不对 → 红" bash -c '[ "$1" -eq 1 ] && grep -q "要 6 列" "$2"' _ "$?" "${TMP}/out"

echo "── 5. plan：gate 与 CI 同一口径"
R="${TMP}/repo"
git init -q "$R"
mkdir -p "$R/tools" "$R/.github/workflows" "$R/apps/ios" "$R/docs" "$R/crates/a"
cp "${SRC}/tools/ci-paths.sh" "${SRC}/tools/ci-needs-full-lane.sh" "$R/tools/"
cat >"$R/.github/workflows/ci-ios.yml" <<'EOF'
jobs:
  changes:
    steps:
      - id: c
        uses: ./.github/actions/changes
        with:
          paths: |
            # 注释行不算
            apps/ios/**
  ios:
    steps: []
EOF
cat >"${TMP}/plan-map.tsv" <<'EOF'
ci-ios.yml	ios	mac	paths	t	echo ios @BASE@
ci-ios.yml	ios	ci-only	-	dev	要真机
ci-rust.yml	test	mac	lane:rust-workspace	n	@PPF_DECODER@ && echo nextest
ci-rust.yml	arch	mac	lane	a	echo arch
ci-rust.yml	test-windows	win	lane:rust-workspace	n	@PPF_DECODER@ && echo win
EOF
printf 'x\n' >"$R/docs/a.md"
printf 'x\n' >"$R/apps/ios/a.swift"
printf 'x\n' >"$R/crates/a/a.rs"
git -C "$R" add -A
git -C "$R" commit -q -m init
B="$(git -C "$R" rev-parse HEAD)"
plan() { python3 "$PY" plan --map "${TMP}/plan-map.tsv" --repo "$R" --base "$B" "$@" 2>/dev/null; }
printf 'y\n' >>"$R/docs/a.md"
git -C "$R" commit -q -am docs
out="$(plan --where mac)"
check "只改 docs → ios（paths）SKIP" bash -c 'printf "%s\n" "$1" | grep -q "^SKIP	ci-ios.yml:ios	"' _ "$out"
check "只改 docs → rust-workspace lane SKIP" bash -c 'printf "%s\n" "$1" | grep -q "^SKIP	ci-rust.yml:test	"' _ "$out"
check "只能 CI 项不论 gate 都列出" bash -c 'printf "%s\n" "$1" | grep -q "^CIONLY	ci-ios.yml:ios/dev	要真机$"' _ "$out"
printf 'y\n' >>"$R/apps/ios/a.swift"
git -C "$R" commit -q -am ios
out="$(plan --where mac)"
check "反证：改了 apps/ios → ios RUN，@BASE@ 替换成基准" bash -c 'printf "%s\n" "$1" | grep -q "^RUN	ci-ios.yml:ios/t	echo ios $2$"' _ "$out" "$B"
check "只改 apps/ → 默认 lane（arch）RUN、rust-workspace lane 仍 SKIP" bash -c \
  'printf "%s\n" "$1" | grep -q "^RUN	ci-rust.yml:arch/a	" && printf "%s\n" "$1" | grep -q "^SKIP	ci-rust.yml:test	"' _ "$out"
printf 'y\n' >>"$R/crates/a/a.rs"
git -C "$R" commit -q -am rust
out="$(plan --where mac)"
check "反证：改了 crates → rust-workspace lane RUN" bash -c 'printf "%s\n" "$1" | grep -q "^RUN	ci-rust.yml:test/n	"' _ "$out"
check "--where mac 不出 win 的步骤" bash -c '! printf "%s\n" "$1" | grep -q "echo win"' _ "$out"
git -C "$R" reset -q --hard "$B"
printf 'y\n' >>"$R/docs/a.md"
git -C "$R" commit -q -am docs2
out="$(plan --where mac --only ci-ios.yml:ios)"
check "--only 忽略 gate，只列指定 job" bash -c \
  'printf "%s\n" "$1" | grep -q "^RUN	ci-ios.yml:ios/t	" && ! printf "%s\n" "$1" | grep -q "ci-rust"' _ "$out"
python3 "$PY" plan --map "${TMP}/plan-map.tsv" --repo "$R" --where mac --only nope.yml:x >/dev/null 2>&1
check "--only 写了对照表里没有的 job → 拒绝（退出码 2）" test "$?" -eq 2
rm "$R/tools/ci-paths.sh"
out="$(plan --where mac)"
check "判据脚本缺失 → 按要跑（fail-closed）" bash -c 'printf "%s\n" "$1" | grep -q "^RUN	ci-ios.yml:ios/t	"' _ "$out"

echo "── 6. @PPF_DECODER@：工作区有 ppf-decoder 就先构建它"
mkdir -p "${TMP}/bin-dec" "${TMP}/bin-nodec"
cat >"${TMP}/bin-dec/cargo" <<'EOF'
#!/usr/bin/env bash
echo '{"packages":[{"name":"daemon","targets":[{"name":"daemon","kind":["bin"]}]},{"name":"decode-worker","targets":[{"name":"ppf-decoder","kind":["bin"]}]}]}'
EOF
printf '#!/usr/bin/env bash\necho {\\"packages\\":[]}\n' >"${TMP}/bin-nodec/cargo"
chmod +x "${TMP}/bin-dec/cargo" "${TMP}/bin-nodec/cargo"
out="$(PATH="${TMP}/bin-dec:$PATH" plan --where mac --only ci-rust.yml:test)"
check "有 ppf-decoder → 本机 nextest 前先 cargo build -p decode-worker --bin ppf-decoder" bash -c \
  'printf "%s\n" "$1" | grep -q "^RUN	ci-rust.yml:test/n	cargo build -p decode-worker --bin ppf-decoder && echo nextest$"' _ "$out"
out="$(PATH="${TMP}/bin-dec:$PATH" plan --where win --only ci-rust.yml:test-windows)"
check "Windows 同样先构建" bash -c 'printf "%s\n" "$1" | grep -q "^RUN	.*	cargo build -p decode-worker --bin ppf-decoder && echo win$"' _ "$out"
out="$(PATH="${TMP}/bin-nodec:$PATH" plan --where mac --only ci-rust.yml:test)"
check "反证：没有 ppf-decoder → 空操作" bash -c 'printf "%s\n" "$1" | grep -q "^RUN	ci-rust.yml:test/n	true && echo nextest$"' _ "$out"

echo "── 7. owner-ci-local.sh：在 --repo 里跑，红即停，报告分三类"
cat >"${TMP}/run-map.tsv" <<EOF
ci-a.yml	one	mac	always	pwd	pwd >"${TMP}/pwd-one"
ci-a.yml	one	mac	always	cd-does-not-leak	cd docs
ci-a.yml	one	mac	always	second	pwd >"${TMP}/pwd-two"
ci-a.yml	two	mac	always	maybe-red	[ ! -e "${TMP}/make-red" ]
ci-a.yml	two	mac	always	after-red	touch "${TMP}/after-red-ran"
ci-a.yml	two	ci-only	-	linux	只能 Linux
EOF
O="${TMP}/out-ok"
out="$(PPASS_CI_LOCAL_MAP="${TMP}/run-map.tsv" bash "${SRC}/tools/flow/owner-ci-local.sh" --repo "$R" --out "$O" --base "$B" 2>/dev/null)"
check "全绿 → 最后一行 CI-LOCAL PASS 5" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "CI-LOCAL PASS 5" ]' _ "$out"
check "命令在 --repo 里跑，上一步的 cd 不串到下一步" bash -c '[ "$(cat "$1/pwd-one")" = "$2" ] && [ "$(cat "$1/pwd-two")" = "$2" ]' _ "$TMP" "$(cd "$R" && pwd -P)"
check "rows.md 每步一行 PASS" test "$(grep -c '| PASS |' "$O/rows.md")" -eq 5
check "ci-only.md 列出只能 CI 项" grep -q '^- ci-a.yml:two/linux：只能 Linux$' "$O/ci-only.md"
touch "${TMP}/make-red"
rm -f "${TMP}/after-red-ran"
O="${TMP}/out-red"
out="$(PPASS_CI_LOCAL_MAP="${TMP}/run-map.tsv" bash "${SRC}/tools/flow/owner-ci-local.sh" --repo "$R" --out "$O" --base "$B" 2>/dev/null)"
rc=$?
check "一步红 → 退出 1，最后一行 CI-LOCAL FAIL <步骤>" bash -c '[ "$1" -eq 1 ] && [ "$(printf "%s\n" "$2" | tail -1)" = "CI-LOCAL FAIL ci-a.yml:two/maybe-red" ]' _ "$rc" "$out"
check "红了就停，后面的步骤不跑" test ! -e "${TMP}/after-red-ran"
check "rows.md 记下红的那步" grep -q '^| ci-a.yml:two/maybe-red | FAIL' "$O/rows.md"
rm -f "${TMP}/make-red"

echo
echo "ci-local-map: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
