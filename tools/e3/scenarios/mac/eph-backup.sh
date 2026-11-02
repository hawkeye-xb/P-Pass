# 冒烟③（M-iroh）：候选构建的 daemon（--ephemeral 桩）与 testclient（扮手机）配对，备份 N 个文件，
# 两边计数一致、桩日志无 panic。
# 反证：从桩索引里删掉一条资产，计数对不上 ⇒ 必须判红。
DESC="候选 daemon 与 testclient 配对并备份 N 张，两端计数一致、无 panic"
COUNTER=off
N="${E3_MAC_N:-30}"

setup() {
  EPH_STATE="$E3_STATE/eph-mac"
  [ -x "$(cand_daemon)" ] && [ -x "$(cand_testclient)" ] || { echo "候选二进制没编：$(cand_daemon) / $(cand_testclient)"; return 1; }
  eph_start "$(cand_daemon)"
  W="$E3_STATE/mac-tc"
  rm -rf "$W"
  mkdir -p "$W"
}

collect() { # 把判定要读的原始输出都写进 $OUT
  eph_ipc status >"$OUT/stub-status.json"
  eph_ipc devices.list >"$OUT/stub-devices.json"
  cp "$EPH_STATE/d.log" "$OUT/stub-daemon.log"
  cp "$W"/tc-*.out "$OUT/" 2>/dev/null
  # testclient 每第 10 个文件复用前一个的内容（去重演示，见 tools/testclient 的语料生成），
  # 所以桩里应有的不同照片数 = N - (N-1)/10。
  echo $((N - (N - 1) / 10)) >"$OUT/sent.txt"
}

act() {
  local qr node code n i tc
  "$(cand_daemon)" --version --json >"$OUT/daemon-version.json" 2>&1
  qr=$(eph_qr)
  T 120 "$(cand_testclient)" pair --token "$qr" --name e3-mac --identity "$W/a.key" >"$W/tc-pair.out" 2>&1 &
  tc=$!
  for i in $(seq 1 60); do
    code=$(sed -n 's/^PAIR_CODE=\([0-9]*\) .*/\1/p' "$W/tc-pair.out")
    [ -n "$code" ] && break
    sleep 0.5
  done
  n=$(grep -o 'node=[0-9a-f]*' "$W/tc-pair.out" | head -1 | cut -d= -f2)
  for i in $(seq 1 30); do eph_ipc pairing.pending | grep -q "$n" && break; sleep 0.5; done
  eph_ipc pairing.confirm "{\"accept\":true,\"node_id\":\"$n\",\"code\":\"$code\"}" >"$OUT/confirm.json"
  wait "$tc"
  node=$(eph_qr | sed -n 's/.*node=\([0-9a-f]\{64\}\).*/\1/p')
  T 300 "$(cand_testclient)" backup --files "$N" --node "$node" --identity "$W/a.key" >"$W/tc-backup.out" 2>&1
  eph_wait_count "$N" 60
  collect
}

judge() {
  local d="$1" got
  got=$(jget "$d/stub-status.json" 'j["result"]["photo_count"]')
  check "testclient 配对成功" has_line "$d/confirm.json" '"ok": ?true'
  check "testclient 报备份完成" has_line "$d/tc-backup.out" '备份完成'
  check "桩里照片数 = 发送的不同内容数（$got / $(cat "$d/sent.txt" 2>/dev/null)）" [ "$got" = "$(cat "$d/sent.txt" 2>/dev/null)" ]
  check "桩日志无 panic" no_line "$d/stub-daemon.log" 'panicked|PANIC'
  verdict
}

counter() {
  # 删掉一条资产：计数对不上必须判红
  cp "$EV/main/"* "$OUT/"
  eph_sql "delete from asset where rowid = (select min(rowid) from asset)"
  sleep 1
  eph_ipc status >"$OUT/stub-status.json"
}

teardown() { eph_stop; }
