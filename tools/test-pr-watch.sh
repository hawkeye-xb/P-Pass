#!/usr/bin/env bash
# tools/flow/pr-watch.sh（just pr-watch）的判据测试：假 gh + 假 pr-status，正反例全覆盖。
#
# 用法: tools/test-pr-watch.sh    退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
has() { case "${out}" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
not_has() { case "${out}" in *"$1"*) return 1 ;; *) return 0 ;; esac; }

FAKE="${TMP}/fake"
mkdir -p "${FAKE}" "${TMP}/bin"

# ── 假 gh（状态机由 $FAKE/scenario.json 驱动，按 pr list 调用次数推进 poll）────
cat >"${TMP}/bin/fake-gh" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys

fake = pathlib.Path(os.environ["FAKE"])
args = sys.argv[1:]
with (fake / "gh_calls.log").open("a", encoding="utf-8") as fh:
    fh.write(" ".join(args) + "\n")

scen = json.loads((fake / "scenario.json").read_text(encoding="utf-8"))
poll_f = fake / "poll.idx"
poll = int(poll_f.read_text(encoding="utf-8")) if poll_f.is_file() else 0

if args[:2] == ["pr", "list"]:
    poll += 1
    poll_f.write_text(str(poll), encoding="utf-8")
    polls = scen.get("polls", [])
    idx = min(poll - 1, len(polls) - 1) if polls else 0
    cur = polls[idx] if polls else {}
    if cur.get("list_fail"):
        sys.stderr.write("gh: simulated list error\n")
        sys.exit(1)
    sys.stdout.write(json.dumps(cur.get("open", []), ensure_ascii=False))
    sys.exit(0)

if args[:2] == ["pr", "view"]:
    pr_num = int(args[2])
    # 显式模式下如果没有 pr list，用 pr view 计数推演或取 view_polls
    if scen.get("explicit_advance") and pr_num == scen.get("advance_on_pr", pr_num):
        poll += 1
        poll_f.write_text(str(poll), encoding="utf-8")
    polls = scen.get("polls", [])
    idx = min(max(poll - 1, 0), len(polls) - 1) if polls else 0
    cur = polls[idx] if polls else {}
    views = cur.get("views", {})
    item = views.get(str(pr_num))
    if item is None:
        for p in cur.get("open", []):
            if int(p["number"]) == pr_num:
                item = p
                break
    if item is None:
        sys.stderr.write(f"gh: PR #{pr_num} not found\n")
        sys.exit(1)
    sys.stdout.write(json.dumps(item, ensure_ascii=False))
    sys.exit(0)

sys.stderr.write("unexpected gh call: " + " ".join(args) + "\n")
sys.exit(2)
STUB

# ── 假 pr-status（按当前 poll 读取 $FAKE/scenario.json 里的状态与输出）────
cat >"${TMP}/bin/fake-status" <<'STUB'
#!/usr/bin/env python3
import json, os, pathlib, sys

fake = pathlib.Path(os.environ["FAKE"])
pr_num = str(sys.argv[1])
with (fake / "status_calls.log").open("a", encoding="utf-8") as fh:
    fh.write(pr_num + "\n")

scen = json.loads((fake / "scenario.json").read_text(encoding="utf-8"))
poll_f = fake / "poll.idx"
poll = int(poll_f.read_text(encoding="utf-8")) if poll_f.is_file() else 1
polls = scen.get("polls", [])
idx = min(max(poll - 1, 0), len(polls) - 1) if polls else 0
cur = polls[idx] if polls else {}
st = cur.get("status", {}).get(pr_num)
if st is None:
    sys.stderr.write(f"missing stub status for PR #{pr_num} at poll {poll}\n")
    sys.exit(2)
if st.get("out"):
    sys.stdout.write(st["out"] + "\n")
sys.exit(int(st.get("rc", 0)))
STUB

chmod +x "${TMP}/bin/fake-gh" "${TMP}/bin/fake-status"

export FAKE
export PPASS_HOOK_REPO="owner/repo"
export PR_WATCH_GH_BIN="${TMP}/bin/fake-gh"
export PR_WATCH_STATUS_BIN="${TMP}/bin/fake-status"

SCRIPT="${SRC}/tools/flow/pr-watch.sh"
out=""
rc=0

reset_case() {
  rm -f "${FAKE}/poll.idx" "${FAKE}/gh_calls.log" "${FAKE}/status_calls.log" "${FAKE}/scenario.json"
}

run_watch() {
  local target="${1}"
  shift
  out="$(bash "${target}" --interval 0 "$@" 2>&1)"
  rc=$?
}

printf 'pr-watch：\n'

# ── 1. 全部还在跑 (exit 3) → 等待后某 PR 合入 (exit 0) ────────────────────
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [{"number": 101, "title": "feat: add sync", "headRefOid": "sha101a", "state": "OPEN"}],
      "status": {
        "101": {"rc": 3, "out": "PR #101 feat: add sync\n暂无卡点，等：1 个检查还在跑"}
      }
    },
    {
      "open": [],
      "views": {
        "101": {"number": 101, "title": "feat: add sync", "headRefOid": "sha101a", "state": "MERGED"}
      },
      "status": {
        "101": {"rc": 0, "out": "PR #101 feat: add sync\n✅ 已合入"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state1.txt"
[ "${rc}" -eq 0 ] && ok "场景1：跑完转合入 → 退出码 0" || bad "场景1：应退出 0，实得 ${rc}：${out}"
has "PR #101" && has "MERGED" && has "feat: add sync" && ok "场景1：输出精确 PR 号、MERGED 状态与标题" || bad "场景1：摘要缺少关键信息：${out}"
not_has "暂无卡点，等：" && ok "场景1：等待轮次 0 噪点输出" || bad "场景1：等待轮次泄露了噪点输出：${out}"
polls_cnt="$(cat "${FAKE}/poll.idx")"
[ "${polls_cnt}" -eq 2 ] && ok "场景1：第 1 轮等待、第 2 轮合入退出（polls=2）" || bad "场景1：轮询次数应为 2，实得 ${polls_cnt}"
grep -Fxq "101:sha101a:merged" "${FAKE}/state1.txt" && ok "场景1：state-file 记入 101:sha101a:merged" || bad "场景1：state-file 缺失合入键"

# ── 2. 多 PR 并行：一个还在跑 (exit 3)，另一个先变红 (exit 1) → 立刻退出 1 ──
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [
        {"number": 201, "title": "feat: slow job", "headRefOid": "sha201a", "state": "OPEN"},
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202a", "state": "OPEN"}
      ],
      "status": {
        "201": {"rc": 3, "out": "PR #201 feat: slow job\n暂无卡点，等：1 个检查还在跑"},
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：1 个检查没过"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state2.txt"
[ "${rc}" -eq 1 ] && ok "场景2：并行 PR 先红 → 立刻退出 1" || bad "场景2：应退出 1，实得 ${rc}：${out}"
has "PR #202" && has "FAILED" && has "fix: broken lint" && ok "场景2：报告变红 PR #202 摘要" || bad "场景2：摘要缺少 #202：${out}"
polls_cnt="$(cat "${FAKE}/poll.idx")"
[ "${polls_cnt}" -eq 1 ] && ok "场景2：不被仍在跑的 #201 阻塞（polls=1）" || bad "场景2：应在第 1 轮退出，实得 ${polls_cnt}"
grep -Fxq "202:sha202a:failed" "${FAKE}/state2.txt" && ok "场景2：state-file 记入 202:sha202a:failed" || bad "场景2：state-file 未记录 202:sha202a:failed"

# ── 3a. 去重：同一个 (202, sha202a, failed) 已在 state-file → 不重复报警，等 201 合入 ─
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [
        {"number": 201, "title": "feat: slow job", "headRefOid": "sha201a", "state": "OPEN"},
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202a", "state": "OPEN"}
      ],
      "status": {
        "201": {"rc": 3, "out": "PR #201 feat: slow job\n暂无卡点，等：1 个检查还在跑"},
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：1 个检查没过"}
      }
    },
    {
      "open": [
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202a", "state": "OPEN"}
      ],
      "views": {
        "201": {"number": 201, "title": "feat: slow job", "headRefOid": "sha201a", "state": "MERGED"}
      },
      "status": {
        "201": {"rc": 0, "out": "PR #201 feat: slow job\n✅ 已合入"},
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：1 个检查没过"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state2.txt"
[ "${rc}" -eq 0 ] && ok "场景3a：已处理红灯不重报，等待 #201 合入退出 0" || bad "场景3a：应忽略旧红灯并等 #201 合入，实得 ${rc}：${out}"
has "PR #201" && not_has "PR #202" && ok "场景3a：只报 #201 合入，未误报 #202" || bad "场景3a：输出异常：${out}"

# ── 3b. --ignore-key 去重 ───────────────────────────────────────────────────
rm -f "${FAKE}/poll.idx" "${FAKE}/gh_calls.log" "${FAKE}/status_calls.log"
run_watch "${SCRIPT}" --ignore-key "202:sha202a:failed"
[ "${rc}" -eq 0 ] && has "PR #201" && ok "场景3b：--ignore-key 跳过已忽略红灯" || bad "场景3b：--ignore-key 未生效，rc=${rc}：${out}"

# ── 3c. 同一 PR 推新 sha 后再次变红 → 重新触发报警 ──────────────────────────
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202a", "state": "OPEN"}
      ],
      "status": {
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：1 个检查没过"}
      }
    },
    {
      "open": [
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202b", "state": "OPEN"}
      ],
      "status": {
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：新的检查失败"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state2.txt"
[ "${rc}" -eq 1 ] && ok "场景3c：同一 PR 推新 sha202b 再次变红 → 重新触发退出 1" || bad "场景3c：新 sha 应触发退出 1，实得 ${rc}：${out}"
has "202:sha202b:failed" && ok "场景3c：报告新 key 202:sha202b:failed" || bad "场景3c：未报告新 key：${out}"
grep -Fxq "202:sha202b:failed" "${FAKE}/state2.txt" && ok "场景3c：state-file 追加记录 202:sha202b:failed" || bad "场景3c：state-file 未追加新 key"

# ── 3d. 反证：去掉去重判断 has_key → 场景 3a 立刻红在旧红灯上 ──────────────
sed 's/^has_key() {/has_key() { return 1;/' "${SCRIPT}" >"${TMP}/no-dedup.sh"
if cmp -s "${TMP}/no-dedup.sh" "${SCRIPT}"; then
  bad "场景3d：反证脚本变异失败"
else
  reset_case
  cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [
        {"number": 201, "title": "feat: slow job", "headRefOid": "sha201a", "state": "OPEN"},
        {"number": 202, "title": "fix: broken lint", "headRefOid": "sha202a", "state": "OPEN"}
      ],
      "status": {
        "201": {"rc": 3, "out": "PR #201 feat: slow job\n暂无卡点，等：1 个检查还在跑"},
        "202": {"rc": 1, "out": "PR #202 fix: broken lint\n合不进去：1 个检查没过"}
      }
    }
  ]
}
JSON
  PR_WATCH_FLOW_DIR="${SRC}/tools/flow" run_watch "${TMP}/no-dedup.sh" --state-file "${FAKE}/state2.txt"
  [ "${rc}" -eq 1 ] && has "202:sha202a:failed" && ok "场景3d：反证通过（去掉去重后同一红灯死循环秒退 1）" || bad "场景3d：反证未按预期失败，rc=${rc}：${out}"
fi

# ── 4. 无 open PR 且无跟踪 PR 时干净退出 0 ──────────────────────────────────
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {"open": [], "status": {}}
  ]
}
JSON
run_watch "${SCRIPT}"
[ "${rc}" -eq 0 ] && has "无任何 open PR" && ok "场景4：无 open PR 时干净退出 0" || bad "场景4：应退出 0，实得 ${rc}：${out}"
[ ! -s "${FAKE}/status_calls.log" ] && ok "场景4：未调用 pr-status" || bad "场景4：无 PR 时不应调用 pr-status"

# ── 5. 显式指定 PR 号 + 参数校验 ────────────────────────────────────────────
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "explicit_advance": true,
  "advance_on_pr": 301,
  "polls": [
    {
      "views": {"301": {"number": 301, "title": "explicit pr", "headRefOid": "sha301", "state": "OPEN"}},
      "status": {"301": {"rc": 3, "out": "PR #301 explicit pr\n暂无卡点，等：1 个检查还在跑"}}
    },
    {
      "views": {"301": {"number": 301, "title": "explicit pr", "headRefOid": "sha301", "state": "MERGED"}},
      "status": {"301": {"rc": 0, "out": "PR #301 explicit pr\n✅ 已合入"}}
    }
  ]
}
JSON
run_watch "${SCRIPT}" 301
[ "${rc}" -eq 0 ] && has "PR #301" && has "MERGED" && ok "场景5a：显式 PR 号模式正常等待并合入退出 0" || bad "场景5a：显式 PR 模式失败，rc=${rc}：${out}"
! grep -q "^pr list" "${FAKE}/gh_calls.log" && ok "场景5a：显式模式不调用 gh pr list" || bad "场景5a：显式模式不应调用 gh pr list"

run_watch "${SCRIPT}" --unknown-flag
[ "${rc}" -eq 2 ] && ok "场景5b：非法参数退出 2" || bad "场景5b：非法参数应退出 2，实得 ${rc}"

run_watch "${SCRIPT}" not-a-number
[ "${rc}" -eq 2 ] && ok "场景5c：非数字 PR 号退出 2" || bad "场景5c：非数字 PR 号应退出 2，实得 ${rc}"

# ── 6. 标题/评审正文含「已合入/已关闭」字样时，只信结构化 state，不误判终态 ──
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [{"number": 601, "title": "fix: 处理 已合入 与 MERGED 展示", "headRefOid": "sha601", "state": "OPEN"}],
      "status": {
        "601": {"rc": 0, "out": "PR #601 fix: 处理 已合入 与 MERGED 展示\n✅ 全清"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state6a.txt"
[ "${rc}" -eq 0 ] && has "[CLEAR]" && not_has "[MERGED]" && ok "场景6a：标题含「已合入」但 state=OPEN 时判为 CLEAR 而非 MERGED" || bad "场景6a：误判了终态，rc=${rc}：${out}"
grep -Fxq "601:sha601:clear" "${FAKE}/state6a.txt" && ok "场景6a：state-file 记为 clear" || bad "场景6a：state-file 未记为 clear"

reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [{"number": 602, "title": "fix: 已合入 与 已关闭 文案修复", "headRefOid": "sha602", "state": "OPEN"}],
      "status": {
        "602": {"rc": 1, "out": "PR #602 fix: 已合入 与 已关闭 文案修复\nPRRT_1  foo.sh:10  @reviewer\n    不要从标题推断 已合入 / 已关闭\n合不进去：1 条评审线程没解决"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state6b.txt"
[ "${rc}" -eq 1 ] && has "[FAILED]" && not_has "[CLOSED]" && not_has "[MERGED]" && ok "场景6b：标题/评审正文含「已合入/已关闭」但 state=OPEN 且 exit 1 时判为 FAILED" || bad "场景6b：误判了终态，rc=${rc}：${out}"
grep -Fxq "602:sha602:failed" "${FAKE}/state6b.txt" && ok "场景6b：state-file 记为 failed" || bad "场景6b：state-file 未记为 failed"

# ── 7. 并发 push 竞态：状态查询期间 headRefOid 变化时不写旧 SHA 去重键 ──────
reset_case
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [{"number": 701, "title": "feat: race check", "headRefOid": "sha701_old", "state": "OPEN"}],
      "views": {
        "701": {"number": 701, "title": "feat: race check", "headRefOid": "sha701_new", "state": "OPEN"}
      },
      "status": {
        "701": {"rc": 1, "out": "PR #701 feat: race check\n合不进去：旧提交检查失败"}
      }
    },
    {
      "open": [],
      "views": {
        "701": {"number": 701, "title": "feat: race check", "headRefOid": "sha701_new", "state": "MERGED"}
      },
      "status": {
        "701": {"rc": 0, "out": "PR #701 feat: race check\n✅ 已合入"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/state7.txt"
[ "${rc}" -eq 0 ] && has "PR #701" && has "[MERGED]" && ok "场景7：查询期间发生新 push 时跳过脏读并等下一轮复核" || bad "场景7：并发 push 处理失败，rc=${rc}：${out}"
! grep -q "sha701_old" "${FAKE}/state7.txt" && grep -Fxq "701:sha701_new:merged" "${FAKE}/state7.txt" && ok "场景7：未写入旧 SHA，最终正确记入 sha701_new" || bad "场景7：state-file 记录异常：$(cat "${FAKE}/state7.txt")"

# ── 8. state-file 写入失败时显式报错并退出 2（不静默吞错）──────────────────
reset_case
touch "${FAKE}/not_a_dir"
cat >"${FAKE}/scenario.json" <<'JSON'
{
  "polls": [
    {
      "open": [{"number": 801, "title": "feat: write fail", "headRefOid": "sha801", "state": "OPEN"}],
      "status": {
        "801": {"rc": 1, "out": "PR #801 feat: write fail\n合不进去：1 个检查没过"}
      }
    }
  ]
}
JSON
run_watch "${SCRIPT}" --state-file "${FAKE}/not_a_dir/state8.txt"
[ "${rc}" -eq 2 ] && has "状态文件" && ok "场景8：state-file 写入失败时显式报错并退出 2" || bad "场景8：state-file 写入失败未传播，rc=${rc}：${out}"

printf '\n通过 %d，失败 %d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
