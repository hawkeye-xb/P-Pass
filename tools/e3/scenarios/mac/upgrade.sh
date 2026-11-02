# 冒烟①（M-up）：上一版 release → 覆盖装候选签名包：身份（NodeId）、配对、照片数不变，服务就绪、无 panic。
#
# 测试机只有一个安装槽（docs/decisions/2026-11-02-one-install-per-test-device.md），拿到 mac 设备锁即可覆盖。
# 输入（通用，与将来出包方式无关）：
#   旧版产物   E3_MAC_BASE_TAG（默认取 GitHub Release 上最新的 v* tag），经 restore 下载、校验后安装
#   候选产物   E3_MAC_CAND_APP（CI 出的正式签名包等），默认 just dev mac 编的开发版签名包（lib/mac-install.sh）
#   安装位置   ~/Applications/P-Pass.app（E3_MAC_APP）
# 数据：身份私钥、配对白名单、库绑定都在钥匙串里，全机一份、不随库目录走，所以不换库目录；场景本身
# 不写库，只装包，判定只读（已装 daemon 自己跑 diag export 拿 status 与设备表；NodeId 取日志里的端点 id）。
# 收尾：装回场景开始前的那一份（mac_snapshot / mac_restore_snapshot，也是 tools/e3/restore mac --snapshot）。
#   just verify 设 E3_MAC_KEEP_CANDIDATE=1：本场景结束时留着候选包，让后面的 mac/svc 验候选，全部跑完再装回。
# 反证（--counter）：「升级」时装回旧版而不是候选 ⇒「已装的是候选」必须判红。
DESC="上一版 release→候选签名包覆盖升级：NodeId、配对、照片数不变，就绪、无 panic"
COUNTER=off

source "$E3_LIB/mac-install.sh"

base_tag() {
  [ -n "${E3_MAC_BASE_TAG:-}" ] && { echo "$E3_MAC_BASE_TAG"; return; }
  gh release list -R "${E3_GH_REPO:-hawkeye-xb/P-Pass}" --limit 30 --json tagName -q '.[].tagName' | grep -m1 '^v[0-9]'
}

setup() {
  [ -d "$(mac_cand_app)" ] || { echo "缺候选签名包：$(mac_cand_app)（just verify 会编；或 E3_MAC_CAND_APP=…）"; return 1; }
  [ -d "$MAC_APP" ] && [ -f "$MAC_PLIST" ] || { echo "本机没装 P-Pass（$MAC_APP / LaunchAgent）"; return 1; }
  if [ -z "$(svc_pid)" ]; then
    echo "跳过：本机服务是停着的（按用户停的处理，不替用户拉起）"
    return 77
  fi
  BASE_TAG=$(base_tag)
  [ -n "$BASE_TAG" ] || { echo "取不到上一版 release tag"; return 1; }
  mac_verify_sig "$(mac_cand_app)" || { echo "候选包签名不完整"; return 1; }
  mac_snapshot >/dev/null || { echo "留快照失败"; return 1; }
  SNAP=1
  echo "上一版 ${BASE_TAG}；候选 $(mac_app_version "$(mac_cand_app)")；开始前 $(cat "$E3_STATE/mac-snapshot/version.txt")"
}

# observe <子目录>：只读取证
observe() {
  local d="$OUT/$1"
  mkdir -p "$d"
  mac_diag "$d" || echo "diag export 失败" >"$d/diag-failed.txt"
  mac_node_prefix >"$d/node.txt"
  mac_app_version >"$d/installed-version.txt"
  svc_version >"$d/daemon-version.json"
}

upgrade_to() { # <要装的 .app>
  local mark
  mac_restore_tag "$BASE_TAG" || { echo "装上一版失败" >"$OUT/base-install-failed.txt"; return 1; }
  observe base
  mark=$(log_mark)
  mac_install_app "$1"
  echo $? >"$OUT/install-rc.txt"
  observe after
  log_since "$mark" >"$OUT/after/daemon-log.txt"
  mac_app_version "$(mac_cand_app)" >"$OUT/cand-version.txt"
}

act() { upgrade_to "$(mac_cand_app)"; }

same_paired() { # 两次设备表里「已配对」的 NodeId 前缀集合相同，且不为空
  python3 -I - "$1/base/devices.json" "$1/after/devices.json" <<'PY'
import json, sys
def paired(p):
    return sorted(d["node_id_prefix"] for d in json.load(open(p)) if d.get("paired"))
a, b = paired(sys.argv[1]), paired(sys.argv[2])
print(f"    升级前 {len(a)} 台、升级后 {len(b)} 台")
sys.exit(0 if a and a == b else 1)
PY
}
same_count() {
  local a b
  a=$(jget "$1/base/status.json" 'j["photo_count"]')
  b=$(jget "$1/after/status.json" 'j["photo_count"]')
  echo "    照片数 $a → $b"
  [ -n "$a" ] && [ "$a" = "$b" ]
}
same_node() {
  local a b
  a=$(tr -d '[:space:]' <"$1/base/node.txt" 2>/dev/null)
  b=$(tr -d '[:space:]' <"$1/after/node.txt" 2>/dev/null)
  [ -n "$a" ] && [ "$a" = "$b" ]
}
is_candidate() { [ "$(tr -d '[:space:]' <"$1/after/installed-version.txt")" = "$(tr -d '[:space:]' <"$1/cand-version.txt")" ] &&
  [ "$(jget "$1/after/daemon-version.json" 'j["version"]')" = "$(tr -d '[:space:]' <"$1/cand-version.txt")" ]; }

judge() {
  local d="$1"
  echo "  INFO  上一版 $(cat "$d/base/installed-version.txt" 2>/dev/null) → 候选 $(cat "$d/cand-version.txt" 2>/dev/null)"
  check "装上一版成功" [ ! -f "$d/base-install-failed.txt" ]
  check "覆盖装候选后服务就绪" eq_file "$d/install-rc.txt" 0
  check "已装的是候选（外壳与 daemon 版本）" is_candidate "$d"
  check "NodeId 不变（$(cat "$d/base/node.txt" 2>/dev/null) → $(cat "$d/after/node.txt" 2>/dev/null)）" same_node "$d"
  check "已配对设备不变" same_paired "$d"
  check "照片数不变" same_count "$d"
  check "升级后日志「启动就绪」" has_line "$d/after/daemon-log.txt" '启动就绪$'
  check "升级后日志无 panic" no_line "$d/after/daemon-log.txt" 'panicked|PANIC'
  verdict
}

counter() { upgrade_to "$E3_STATE/releases/$BASE_TAG/app/P-Pass.app"; }

teardown() {
  [ "${SNAP:-}" = 1 ] || return 0
  [ "${E3_MAC_KEEP_CANDIDATE:-}" = 1 ] && { mac_install_app "$(mac_cand_app)"; return 0; }
  mac_restore_snapshot
}
