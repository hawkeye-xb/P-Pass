#!/usr/bin/env bash
# V3 协作工作流核心与模拟演练场的判据测试（含变异反证）：
#   1. v3_harness.py 总行数 <= 400 行硬门禁
#   2. 13 场景全矩阵确定性对抗自测 + 语义冲突变基重验 + 只读 gh 垫片拦截审计全绿
#   3. 反证 A：注释掉锁定测试 SHA256 校验时，T1 偷改测试能够混过关，自测必须判红
#   4. 反证 B：注释掉核心禁区黑名单校验时，T8 越权修改 pairing.py 混过关，隐藏真值裁判必须判红
#   5. 反证 C：让只读 gh 垫片放行 issue edit 时，自测必须判红

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

fail=0
ok() { printf '  ✅ %s\n' "$1"; }
ko() { printf '  ❌ %s\n' "$1"; fail=1; }

chmod +x "${ROOT}/tools/flow/gh-readonly-shim.sh"

# 1. 行数门禁：v3_harness.py <= 400 行
lines="$(wc -l <"${ROOT}/tools/flow/v3_harness.py" | tr -d '[:space:]')"
if [ "${lines}" -le 400 ]; then
  ok "v3_harness.py 行数合规（${lines} <= 400）"
else
  ko "v3_harness.py 行数超标（${lines} > 400）"
fi

# 2. 正向验证：13 场景 + 语义冲突变基 + 只读 gh 垫片全绿
if out="$(python3 -I "${ROOT}/tools/flow/bench/bench.py" selftest 2>&1)"; then
  if printf '%s' "${out}" | grep -q "ALL_13_SCENARIOS_AND_SEMANTIC_REBASE_PASSED"; then
    ok "13 场景对抗自测与语义冲突变基重验全绿"
  else
    ko "bench.py selftest 退出码 0 但未打印预期通过标记：${out}"
  fi
else
  ko "bench.py selftest 失败：${out}"
fi

# 2.5 与真实仓库 .github/core-paths.txt + tools/ci-paths.sh core 逐条同源对齐核验
if python3 -I - "${ROOT}" <<'PY'
import subprocess, sys
root = sys.argv[1]
sys.path.insert(0, f"{root}/tools/flow")
import v3_harness

rules = v3_harness.core_rules_from_git(root, "HEAD")
samples = [
    ".github/core-paths.txt",
    ".github/workflows/release.yml",
    ".github/workflows/repair-manifests.yml",
    ".github/workflows/mirror-latest.yml",
    ".github/workflows/ci-docs.yml",
    "crates/pair-pake/src/lib.rs",
    "crates/daemon/src/pairing.rs",
    "crates/daemon/src/main.rs",
    "apps/desktop/src-tauri/tauri.conf.json",
    "apps/desktop/src/App.svelte",
    "tools/release/sign.sh",
    "tools/flow/v3_harness.py",
]
for s in samples:
    py_ans = v3_harness.is_core_path(s, rules)
    sh_out = subprocess.check_output(["bash", f"{root}/tools/ci-paths.sh", "core", "-", f"{root}/.github/core-paths.txt"], input=s + "\n", text=True).strip()
    sh_ans = (sh_out == "true")
    assert py_ans == sh_ans, f"mismatch on {s}: v3_harness={py_ans} vs ci-paths.sh={sh_ans}"
PY
then
  ok "v3_harness 核心路径匹配与真实 .github/core-paths.txt + tools/ci-paths.sh 100% 同源一致"
else
  ko "v3_harness 与 tools/ci-paths.sh core 匹配结果不一致"
fi

# 构造隔离沙盒做四组变异反证（不改动工作区真实文件）
mut_dir="$(mktemp -d)"
trap 'rm -rf "${mut_dir}"' EXIT
mkdir -p "${mut_dir}/flow/bench"
cp "${ROOT}/tools/flow/v3_harness.py" "${mut_dir}/flow/v3_harness.py"
cp "${ROOT}/tools/flow/gh-readonly-shim.sh" "${mut_dir}/flow/gh-readonly-shim.sh"
chmod +x "${mut_dir}/flow/gh-readonly-shim.sh"
cp "${ROOT}/tools/flow/bench/bootstrap.py" "${mut_dir}/flow/bench/bootstrap.py"
cp "${ROOT}/tools/flow/bench/bench.py" "${mut_dir}/flow/bench/bench.py"

# 3. 反证 A：去掉 SHA256 封条检查必须变红
python3 -I - "${mut_dir}/flow/v3_harness.py" <<'PY' || exit 1
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
old = 'if not re.fullmatch(r"[0-9a-f]{64}", (locked_sha or "").lower()) or sha256_file(exam_abs) != locked_sha.lower():'
mut = src.replace(old, "if False:")
assert mut != src, "failed to mutate sha256 check"
p.write_text(mut, encoding="utf-8")
PY
if python3 -I "${mut_dir}/flow/bench/bench.py" selftest >/dev/null 2>&1; then
  ko "反证 A 失败：去掉 SHA256 封条检查后 selftest 仍然通过"
else
  ok "反证 A 通过：去掉 SHA256 封条检查时 selftest 判红"
fi
cp "${ROOT}/tools/flow/v3_harness.py" "${mut_dir}/flow/v3_harness.py"

# 4. 反证 B：去掉核心路径黑名单检查（含还原）必须变红
python3 -I - "${mut_dir}/flow/v3_harness.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
mut = src.replace('if not task.get("core_approved", False):', "if False:").replace("(not core_approved and is_core_path(f, rules))", "False")
assert mut != src, "failed to mutate core_paths check"
p.write_text(mut, encoding="utf-8")
PY
if python3 -I "${mut_dir}/flow/bench/bench.py" selftest >/dev/null 2>&1; then
  ko "反证 B 失败：去掉核心禁区黑名单检查后 selftest 仍然通过"
else
  ok "反证 B 通过：去掉核心禁区黑名单检查时 selftest 判红"
fi
cp "${ROOT}/tools/flow/v3_harness.py" "${mut_dir}/flow/v3_harness.py"

# 5. 反证 C：让只读 gh 垫片放行 issue:edit 必须变红
python3 -I - "${mut_dir}/flow/gh-readonly-shim.sh" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
mut = src.replace("issue:view | issue:list", "issue:view | issue:list | issue:edit")
assert mut != src, "failed to mutate gh shim"
p.write_text(mut, encoding="utf-8")
PY
if python3 -I "${mut_dir}/flow/bench/bench.py" selftest >/dev/null 2>&1; then
  ko "反证 C 失败：放行 gh issue edit 后 selftest 仍然通过"
else
  ok "反证 C 通过：放行 gh issue edit 时 selftest 判红"
fi
cp "${ROOT}/tools/flow/gh-readonly-shim.sh" "${mut_dir}/flow/gh-readonly-shim.sh"
chmod +x "${mut_dir}/flow/gh-readonly-shim.sh"

# 6. 反证 D：退回错误的前缀剥离 lstrip("./")（导致 .github/* 核心路径漏拦）必须变红
python3 -I - "${mut_dir}/flow/v3_harness.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
src = p.read_text(encoding="utf-8")
old = '    pat = re.sub(r"^(?:\\./)+", "", pat.strip())'
mut = src.replace(old, '    pat = pat.strip().lstrip("./")')
assert mut != src, "failed to mutate lstrip('./')"
p.write_text(mut, encoding="utf-8")
PY
if python3 -I "${mut_dir}/flow/bench/bench.py" selftest >/dev/null 2>&1; then
  ko "反证 D 失败：退回 lstrip('./') 漏拦 .github 核心路径后 selftest 仍然通过"
else
  ok "反证 D 通过：退回 lstrip('./') 漏拦 .github 核心路径时 selftest 判红"
fi
cp "${ROOT}/tools/flow/v3_harness.py" "${mut_dir}/flow/v3_harness.py"

[ "${fail}" -eq 0 ] || exit 1
echo "ok: V3 门禁与模拟演练场全部判据及反证通过"
