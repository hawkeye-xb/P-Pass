#!/usr/bin/env bash
# tools/check-egress.py 的自测：每类违反必须红，还原必须绿。
set -uo pipefail
. "$(dirname "$0")/fitness-test-lib.sh"
CHECK=check-egress.py
new_repo egress-allowlist.txt 'site|crates/base/src/net.rs|基线：已登记的出口'

echo "无遥测 / 外联门禁自测"
put crates/base/src/net.rs 'fn f() { let _ = reqwest::Client::new(); }'
expect_green "基线：已登记的出口通过"

# 站点：各语言的网络出口
put crates/x/src/net.rs 'fn f() { let c = reqwest::Client::new(); }'
expect_red "Rust reqwest 新出口" "site|crates/x/src/net.rs"
unput crates/x/src/net.rs; expect_green "还原：Rust"
put apps/android/app/src/main/java/a/Net.kt 'val c = URL("https://a.example.net").openConnection()'
expect_red "Kotlin URL/openConnection 新出口" "site|apps/android/app/src/main/java/a/Net.kt"
unput apps/android/app/src/main/java/a/Net.kt; expect_green "还原：Kotlin"
put apps/ios/PPass/Net.swift 'let s = URLSession.shared'
expect_red "Swift URLSession 新出口" "site|apps/ios/PPass/Net.swift"
unput apps/ios/PPass/Net.swift; expect_green "还原：Swift"
put apps/desktop/src/lib/beacon.js 'fetch("https://t.example.net/x")'
expect_red "桌面 fetch 新出口" "site|apps/desktop/src/lib/beacon.js"
unput apps/desktop/src/lib/beacon.js; expect_green "还原：桌面"

# 主机名字面量（真实域名；example/invalid 占位不算）
put crates/x/src/url.rs 'const U: &str = "https://stats.tracker-corp.io/v1";'
expect_red "新外部主机" "host|stats.tracker-corp.io"
unput crates/x/src/url.rs
put crates/x/src/url.rs 'const U: &str = "https://relay.example/v1";'
expect_green "占位域名 example 不算"
unput crates/x/src/url.rs

# 注释与内联测试不算
put crates/x/src/c.rs $'// reqwest::Client 的旧写法已删\nfn f() {}\n#[cfg(test)]\nmod t { fn g() { let _ = reqwest::Client::new(); } }'
expect_green "注释 / #[cfg(test)] 之后不算"
unput crates/x/src/c.rs

# 依赖
put crates/x/Cargo.toml $'[dependencies]\nreqwest = "0.12"'
expect_red "新增 HTTP 客户端依赖" "dep|reqwest"
unput crates/x/Cargo.toml; expect_green "还原：依赖"
put apps/desktop/package.json '{"dependencies":{"@sentry/browser":"^8"}}'
expect_red "遥测 SDK（硬禁令）" "禁用的遥测"
unput apps/desktop/package.json
put apps/android/app/build.gradle.kts 'implementation("com.google.firebase:firebase-analytics:21")'
expect_red "遥测 SDK（Gradle firebase）" "禁用的遥测"
unput apps/android/app/build.gradle.kts; expect_green "还原：遥测"

# 登记表自身：说明为空 → 红；登记了却已不存在 → 红
cp "$R/tools/egress-allowlist.txt" "$TMP/base.txt"
printf 'site|crates/gone/src/old.rs|\n' >>"$R/tools/egress-allowlist.txt"
expect_red "登记缺用途" "说明不许留空"
cp "$TMP/base.txt" "$R/tools/egress-allowlist.txt"
printf 'site|crates/gone/src/old.rs|已删除的旧出口\n' >>"$R/tools/egress-allowlist.txt"
expect_red "登记了但代码里已找不到" "已找不到"
cp "$TMP/base.txt" "$R/tools/egress-allowlist.txt"
expect_green "还原：登记表"
finish
