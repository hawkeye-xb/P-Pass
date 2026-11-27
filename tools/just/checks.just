# 架构、适应度、文档锚点、安全合规与流程门禁检查配方

# Architecture check: enforce isolation rules
# #1040：先跑门禁自测（违规样例必须红、合规样例必须过），再判真实代码。
# 想只看 G1/G5 现状而不判红：ARCH_REPORT_ONLY=1 ./tools/arch-check.sh
arch-check:
  @./tools/test-arch-check.sh
  @./tools/arch-check.sh

# 产品理念的适应度函数（docs/runbook/fitness.md）：无遥测/不新增外联、尊重用户停服务、
# 占盘 1x 的结构信号。每条先跑自测（违反必须红、还原必须绿）再判真实仓库。
# 同一组命令在 ci-rust.yml 的 `fitness-check` job 里跑。
fitness-check:
  @tools/test-check-egress.sh
  @python3 tools/check-egress.py
  @tools/test-check-autostart.sh
  @python3 tools/check-autostart.py
  @tools/test-check-disk-growth.sh
  @python3 tools/check-disk-growth.py

# Markdown tables in docs/ must not be split by a stray blank line
#
# QA-07: 解释器不能硬写 `python3`。Windows 上 `python3` 常解析到 Microsoft Store
# 的应用执行别名占位程序——它**存在于 PATH**、但零输出、非零退出（本机实测
# exit 49），所以 `command -v python3` 这类探测会被它骗过，必须真跑一次才判得出
# 活死。反过来也不能一律改写成 `python`：Debian 系只保证有 `python3`。
# 故：依次试 python3 / python / py，第一个能自报 major == 3 的胜出。
#
# 用 shebang 配方是刻意的——它绕开 just 的 shell 设置，将来若为 Windows 配上
# `set windows-shell`（QA-08）这两条不会跟着坏。
doc-anchors-check:
  @python3 tools/check-doc-anchors.py --tier 1
  @python3 tools/check-doc-anchors.py --tier 2

md-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-markdown-tables.py
    fi
  done
  echo "md-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# SEC-02: 提交身份必须在 .github/allowed-identities.txt 白名单内。
# 第二行是反证（证明门禁在该红时真的红），跟门禁同生共死。
# 本地跑的是 origin/main..HEAD；远端 ci-identity.yml 按 PR/push 各自算区间。
# shell 变量紧挨非 ASCII 字符必须写成 ${name}：macOS /bin/bash 3.2 会把多字节字符的首字节读进变量名
# （v0.9.12-test.5 的 macOS 构建因此没能重试 codesign）。先跑自测，再扫全仓。
shell-vars-check:
  @python3 tools/check-shell-vars.py --self-test
  @python3 tools/check-shell-vars.py

identity-check:
  @./tools/test-commit-identity-gate.sh
  @./tools/check-commit-identity.sh

# 本地提交拦截（本机安全链 + 核心禁区黑名单），说明见 docs/runbook/local-hooks.md。
# hooks-test：临时仓库 + 假 gh 跑全部判据与反证，进 ci / ci-docs（纯 shell，几秒）。
# hooks-check：检查本机是否装好（core.hooksPath 与转发器），没装好非 0 退出，修复跑 just setup。
hooks-test:
  @bash tools/test-local-hooks.sh

hooks-check:
  @bash tools/hooks/install.sh --check

# SEC-09 (#371): pnpm 的 minimumReleaseAgeExclude 不许自己长出来。
# 任何条目都要在 tools/release-age-exclude-allowlist.txt 显式登记；先跑变异反证再扫全仓。
supply-chain-check:
  @bash tools/test-release-age-exclude.sh
  @python3 tools/check-release-age-exclude.py

# Full CI pipeline (same as GitHub Actions pr.yml)
ci: fmt toolchain-check lint lint-cross test arch-check fitness-check md-check doc-anchors-check token-check shell-vars-check identity-check supply-chain-check mobile-static-check build-stamp-check i18n-split-check lockfile-check flow-tests heavy-lock-test
  @echo "==> CI pipeline: all green ✅"

# ci-ios 里不需要模拟器的文字级门禁 + 手机端 i18n 副本，本地几秒跑完。
# 为什么要这条：改了 assets/i18n 却没同步副本，本地 `ci` 全绿、要等远端 iOS lane 才红。
mobile-static-check:
  python3 tools/ios/gen-tokens.py --check
  tools/ios/sync-i18n.sh --check
  tools/ios/test-stamp-version.sh > /dev/null
  tools/ios/check-testflight-signing.sh --self-test > /dev/null
  tools/ios/check-testflight-signing.sh
  python3 tools/ios/gen-strings.py --check
  python3 tools/check-dead-i18n.py --self-test > /dev/null
  python3 tools/check-dead-i18n.py
  python3 tools/check-desktop-dead-components.py --self-test > /dev/null
  python3 tools/check-desktop-dead-components.py
  tools/ios/check-no-color-literals.sh --self-test > /dev/null
  tools/ios/check-no-color-literals.sh
  tools/check-ui-truth-table.sh --self-test > /dev/null
  tools/check-ui-truth-table.sh
  @for l in en zh; do cmp -s assets/i18n/$l.json apps/android/app/src/main/assets/i18n/$l.json || { echo "✗ apps/android/app/src/main/assets/i18n/$l.json 与 assets/i18n 不一致——从 assets/i18n 复制过去"; exit 1; }; done
  @echo "ok: Android i18n 副本与 assets/i18n 逐字节一致"

# #1820 本地构建时间与设备测试保留 App 的口径自测（纯 shell，几秒；进 ci / ci-docs）。
# 断言：两端都从 PPF_BUILD_STAMP 取值；stamp 为空时版本行只显示版本号+构建号、非空时追加；
# 设备测试 recipe 带 leaveApksInstalledAfterRun=true；本地 `just dev` 用 date '+%m-%d %H:%M' 生成时间戳。
# recipe 级断言只看对应配方/构建脚本的正文（不看整份文件，避免匹配到注释或断言自身的字符串），
# Android/Swift 字面量断言只看非注释行（含跨行 /* ... */ 块注释），配方级断言忽略缩进注释，并带反证：
# 删掉或缩进注释掉时间戳注入与 connected 命令、删掉/注释掉 iOS 的 Add 行、删掉或注释掉 trim 任一段、
# 注释掉（// 或 /* */ 包起来）Android 的 System.getenv 并改回返回空串、删掉或注释掉 HomeScreen appVersionLine() 调用或分支时必须判红。
build-stamp-check:
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{ justfile_directory() }}"
    fail=0
    ok() { printf '  ✅ %s\n' "$1"; }
    ko() { printf '  ❌ %s\n' "$1"; fail=1; }
    noncomment() { # <file>：去掉注释（跨行 /* ... */、行注释 // 与 #、块注释续行 *），注释里的字面量不算
      # 逐字符扫，字符串引号内的 // 与 /* 不算注释（如 "crates/proto/**"）。
      awk '
        function strip(s,   out, i, n, ch, nx, closed, q) {
          out = ""; n = length(s); i = 1
          while (i <= n) {
            ch = substr(s, i, 1)
            if (q != "") {
              out = out ch
              if (ch == "\\" && i < n) { out = out substr(s, i + 1, 1); i += 2; continue }
              if (ch == q) q = ""
              i++; continue
            }
            if (ch == "\"") { q = ch; out = out ch; i++; continue }
            if (ch == "/" && i < n) {
              nx = substr(s, i + 1, 1)
              if (nx == "/") return out
              if (nx == "*") {
                i += 2; closed = 0
                while (i < n) {
                  if (substr(s, i, 1) == "*" && substr(s, i + 1, 1) == "/") { i += 2; closed = 1; break }
                  i++
                }
                if (!closed) { inblock = 1; return out }
                continue
              }
            }
            out = out ch; i++
          }
          return out
        }
        inblock {
          b = index($0, "*/")
          if (b == 0) next
          $0 = substr($0, b + 2); inblock = 0
        }
        { print strip($0) }
      ' "$1"
    }
    # 从 stdin 找字面量 / 正则。读完整输入，不用 grep -q：-q 一命中就关掉管道读端，
    # 生产者（awk/sed/grep）还在往下写就吃 SIGPIPE 死在 141，本 recipe 的 set -o pipefail
    # 于是把整条管道报成失败——文件一大就被误判成「找不到」（#1890）。
    stdin_has() { grep -F -- "$1" >/dev/null; }
    stdin_has_re() { grep -E -- "$1" >/dev/null; }
    has_literal() { # <file> <literal>：只在非注释行里找字面量
      noncomment "$1" | stdin_has "$2"
    }
    need() { # <file> <literal> <说明>
      if has_literal "$1" "$2"; then ok "$3"; else ko "$3（$1 里找不到「$2」）"; fi
    }
    show_recipe() { # <配方名> <输出文件>：通过 just --show 读取实际加载并生效的配方正文（未导入的备份 .just 不算数）
      just --justfile "{{ justfile_directory() }}/justfile" --show "$1" >"$2" 2>/dev/null && [ -s "$2" ]
    }
    recipe_body() { # <justfile> <配方头正则>：从配方头到下一个配方头（列 0 的小写名 + 空格/冒号）
      sed -n "/^$2/,/^[a-z][a-z0-9-]*[ :]/p" "$1"
    }
    has_dev_stamp() { # 时间戳注入只在 dev 配方正文里找（缩进注释不算）
      recipe_body "$1" 'dev \*args:' | grep -Ev '^[[:space:]]*#' | stdin_has 'export PPF_BUILD_STAMP=' &&
        recipe_body "$1" 'dev \*args:' | grep -Ev '^[[:space:]]*#' | stdin_has "date '+%m-%d %H:%M'"
    }
    has_keep_apks() { # 设备测试命令与参数只在 android-instrumented 正文里找（缩进注释不算）
      recipe_body "$1" 'android-instrumented \*args:' | grep -Ev '^[[:space:]]*#' | stdin_has 'connectedDebugAndroidTest' &&
        recipe_body "$1" 'android-instrumented \*args:' | grep -Ev '^[[:space:]]*#' | stdin_has 'android.injected.androidTest.leaveApksInstalledAfterRun=true'
    }
    ios_stamp_script() { # <project.yml>：只取「Stamp build time」脚本正文（按缩进判定，注释/Delete 行在外面）
      awk '
        { match($0, /^ */); ind = RLENGTH }
        !inblock && /- name: Stamp build time/ { inblock = 1; next }
        inblock && !inscript && /script: \|/ { inscript = 1; scriptind = ind; next }
        inscript {
          if ($0 ~ /^[[:space:]]*$/) next
          if (ind > scriptind) { sub(/^ +/, ""); print; next }
          exit
        }
      ' "$1"
    }
    ios_has_env() { ios_stamp_script "$1" | grep -Ev '^[[:space:]]*#' | stdin_has 'PPF_BUILD_STAMP'; }
    ios_has_add() { # 真正的（非注释）Add 命令行
      ios_stamp_script "$1" | stdin_has_re '^[[:space:]]*/usr/libexec/PlistBuddy -c "Add :PPassBuildStamp string'
    }
    ios_has_trim() { # tr -d 与首尾 trim 三段都在（注释行不算，与 ios_has_env 同一口径）
      local b
      b="$(ios_stamp_script "$1" | grep -Ev '^[[:space:]]*#')"
      printf '%s\n' "$b" | stdin_has 'tr -d' &&
        printf '%s\n' "$b" | stdin_has 's/^[[:space:]]*//' &&
        printf '%s\n' "$b" | stdin_has 's/[[:space:]]*$//'
    }
    remove_seg() { # <file> <literal>：删掉第一处字面量（反证用）
      awk -v seg="$2" '{ i = index($0, seg); if (i > 0) $0 = substr($0, 1, i-1) substr($0, i+length(seg)); print }' "$1"
    }
    comment_kt_line() { # <file> <literal>：将命中字面量的整行用 // 注释掉（反证用）
      awk -v seg="$2" 'index($0, seg) > 0 { print "// " $0; next } { print }' "$1"
    }
    refute_literal() { # <file> <literal> <说明>：反证副本里找不到字面量才判绿
      if has_literal "$1" "$2"; then ko "反证：${3}后检查仍通过"; else ok "反证：${3} → 判红"; fi
    }
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ppass-stamp.XXXXXX")" || { ko "建临时目录失败，反证跑不了"; exit 1; }
    trap 'rm -rf "$tmp"' EXIT

    # 1) 时间戳来源：只看 dev 配方正文（通过 just --show 读取实际生效配方），格式能分辨先后（MM-DD HH:MM）。
    dev_recipe="$tmp/recipe-dev.just"
    if show_recipe dev "$dev_recipe" && has_dev_stamp "$dev_recipe"; then
      ok "just dev 配方用 date 注入 PPF_BUILD_STAMP"
    else
      ko "just dev 配方无法解析或缺少时间戳注入"
      dev_recipe=""
    fi
    stamp="$(date '+%m-%d %H:%M')"
    case "$stamp" in
      [0-9][0-9]-[0-9][0-9]" "[0-9][0-9]:[0-9][0-9]) ok "date 产出 MM-DD HH:MM（${stamp}）" ;;
      *) ko "date 产出不是 MM-DD HH:MM（${stamp}）" ;;
    esac

    # 2) Android：构建期读 PPF_BUILD_STAMP 写进 BuildConfig；appVersionLine() 空/非空两条分支及调用都在。
    home_kt="apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/HomeScreen.kt"
    need apps/android/app/build.gradle.kts 'System.getenv("PPF_BUILD_STAMP")' "Android 构建读 PPF_BUILD_STAMP"
    need apps/android/app/build.gradle.kts 'buildConfigField("String", "BUILD_STAMP"' "Android 写 BuildConfig.BUILD_STAMP"
    need "$home_kt" 'BuildConfig.VERSION_NAME' "版本行读 VERSION_NAME"
    need "$home_kt" 'BuildConfig.VERSION_CODE' "版本行读 VERSION_CODE"
    need "$home_kt" 'BuildConfig.BUILD_STAMP' "版本行读 BUILD_STAMP"
    need "$home_kt" 'value = appVersionLine()' "版本行调用 appVersionLine()"
    need "$home_kt" 'if (buildStamp.isBlank())' "stamp 为空时走不追加时间的分支"
    need "$home_kt" '"$versionName ($versionCode)"' "空 stamp 分支只显示版本号+构建号"
    need "$home_kt" '"$versionName ($versionCode) $buildStamp"' "非空 stamp 追加到版本行"
    need "$home_kt" '$buildStamp' "非空 stamp 分支引用 buildStamp"

    # 3) iOS：只看「Stamp build time」脚本正文；注释、Delete 行都不算。
    ios_body="$(ios_stamp_script apps/ios/project.yml)"
    if [ -n "$ios_body" ]; then ok "提取到 Stamp build time 脚本正文"; else ko "找不到 Stamp build time 脚本正文"; fi
    if ios_has_env apps/ios/project.yml; then ok "iOS 构建脚本读 PPF_BUILD_STAMP"; else ko "iOS 构建脚本没读 PPF_BUILD_STAMP"; fi
    if ios_has_add apps/ios/project.yml; then ok "iOS 构建脚本真正 Add PPassBuildStamp（非注释）"; else ko "iOS 构建脚本没有非注释的 Add :PPassBuildStamp 行"; fi
    if ios_has_trim apps/ios/project.yml; then ok "iOS 写入前 trim 换行/首尾空白（tr -d + 两段 sed）"; else ko "iOS 写入前 trim 不完整"; fi
    if printf '%s\n' "$ios_body" | stdin_has '[ -n "$stamp" ]'; then ok "stamp 为空时不写 PPassBuildStamp"; else ko "stamp 为空时的判断缺失"; fi
    need apps/ios/PPass/Diagnostics/AppVersion.swift 'info["PPassBuildStamp"]' "AppVersion 读 PPassBuildStamp"
    need apps/ios/PPass/Diagnostics/AppVersion.swift 'let stamp = buildStamp.trimmingCharacters(in: .whitespaces)' "空/空白 stamp 归一处理"
    need apps/ios/PPass/Diagnostics/AppVersion.swift 'stamp.isEmpty ? base :' "空 stamp 只显示 base、非空追加"
    # 用构建阶段的真实脚本跑临时 plist：含空格（首尾也带空白）的值应被 trim 后写入；空值应删除键。
    if command -v plutil >/dev/null 2>&1 && [ -x /usr/libexec/PlistBuddy ]; then
      mkdir -p "$tmp/build"
      cp apps/ios/PPass/Info.plist "$tmp/build/Info.plist"
      TARGET_BUILD_DIR="$tmp/build" INFOPLIST_PATH=Info.plist PPF_BUILD_STAMP='  11-17 11:30  ' bash -c "$ios_body"
      got="$(/usr/libexec/PlistBuddy -c "Print :PPassBuildStamp" "$tmp/build/Info.plist" 2>/dev/null || true)"
      if [ "$got" = "11-17 11:30" ]; then ok "真实脚本写入含空格值并 trim 后读回一致"; else ko "真实脚本读回不一致（得到「${got}」）"; fi
      cp apps/ios/PPass/Info.plist "$tmp/build/Info.plist"
      TARGET_BUILD_DIR="$tmp/build" INFOPLIST_PATH=Info.plist env -u PPF_BUILD_STAMP bash -c "$ios_body"
      if /usr/libexec/PlistBuddy -c "Print :PPassBuildStamp" "$tmp/build/Info.plist" >/dev/null 2>&1; then
        ko "空 stamp 仍在 plist 里写入 PPassBuildStamp"
      else
        ok "真实脚本在空 stamp 时不写 PPassBuildStamp"
      fi
    else
      echo "  ⏭ 非 macOS：跳过 PlistBuddy 真实写入测试"
    fi

    # 4) 设备测试：只看 android-instrumented 正文（通过 just --show 读取实际生效配方）；just android-test（JVM 单测）语义不变。
    android_inst_recipe="$tmp/recipe-android-inst.just"
    android_test_recipe="$tmp/recipe-android-test.just"
    if show_recipe android-instrumented "$android_inst_recipe" && has_keep_apks "$android_inst_recipe"; then
      ok "android-instrumented 跑 connected 并带 keep-apks 参数"
    else
      ko "android-instrumented 无法解析或缺少 connected 命令或 keep-apks 参数"
      android_inst_recipe=""
    fi
    if ! show_recipe android-test "$android_test_recipe"; then
      ko "无法解析 android-test 配方"
    elif recipe_body "$android_test_recipe" 'android-test:' | stdin_has 'connectedDebugAndroidTest'; then
      ko "just android-test 仍是 JVM 单测，不该跑 connectedDebugAndroidTest"
    else
      ok "just android-test 仍是 JVM 单测（未跑 connectedDebugAndroidTest）"
    fi

    # 5) 反证：删掉时间戳注入 / connected 命令 / iOS 的 Add 行 / trim 任一段后，上面的断言必须判红；
    #    且无法解析的配方（或未导入的备份 .just 影子配方）也必须判红。
    if show_recipe '__nonexistent_stamp_recipe__' "$tmp/missing-recipe.just"; then
      ko "反证：不存在的配方竟然被 just --show 解析成功"
    else
      ok "反证：未生效/不存在的配方 → 判红"
    fi
    if [ -n "$dev_recipe" ]; then
      grep -v 'export PPF_BUILD_STAMP=' "$dev_recipe" >"$tmp/justfile-no-stamp"
      if has_dev_stamp "$tmp/justfile-no-stamp"; then
        ko "反证：删掉时间戳注入后检查仍通过"
      else
        ok "反证：删掉时间戳注入 → 判红"
      fi
      sed 's/^\( *\)export PPF_BUILD_STAMP=/\1# export PPF_BUILD_STAMP=/' "$dev_recipe" >"$tmp/justfile-commented-stamp"
      if has_dev_stamp "$tmp/justfile-commented-stamp"; then
        ko "反证：把时间戳注入缩进注释掉后检查仍通过"
      else
        ok "反证：把时间戳注入缩进注释掉 → 判红"
      fi
    fi
    if [ -n "$android_inst_recipe" ]; then
      grep -v 'connectedDebugAndroidTest' "$android_inst_recipe" >"$tmp/justfile-no-connected"
      if has_keep_apks "$tmp/justfile-no-connected"; then
        ko "反证：删掉 connected 命令后检查仍通过"
      else
        ok "反证：删掉 connected 命令 → 判红"
      fi
      sed '/connectedDebugAndroidTest/ s/^\( *\)/\1# /' "$android_inst_recipe" >"$tmp/justfile-commented-connected"
      if has_keep_apks "$tmp/justfile-commented-connected"; then
        ko "反证：把 connected 命令缩进注释掉后检查仍通过"
      else
        ok "反证：把 connected 命令缩进注释掉 → 判红"
      fi
    fi
    # 注释掉 System.getenv 并改回返回空串：非注释断言必须判红，注释副本保留 buildConfigField 行作对照。
    awk '
      /System.getenv\("PPF_BUILD_STAMP"\)/ { print "// " $0; print "    \"\""; next }
      { print }
    ' apps/android/app/build.gradle.kts >"$tmp/build-commented-stamp.kts"
    awk '
      /System.getenv\("PPF_BUILD_STAMP"\)/ { print "/*"; print $0; print "*/"; print "    \"\""; next }
      { print }
    ' apps/android/app/build.gradle.kts >"$tmp/build-block-commented-stamp.kts"
    if has_literal "$tmp/build-block-commented-stamp.kts" 'System.getenv("PPF_BUILD_STAMP")'; then
      ko "反证：把 System.getenv(\"PPF_BUILD_STAMP\") 包进 /* */ 并返回空串后检查仍通过"
    else
      ok "反证：把 System.getenv(\"PPF_BUILD_STAMP\") 包进 /* */ 并返回空串 → 判红"
    fi
    if has_literal "$tmp/build-commented-stamp.kts" 'System.getenv("PPF_BUILD_STAMP")'; then
      ko "反证：注释掉 System.getenv(\"PPF_BUILD_STAMP\") 并返回空串后检查仍通过"
    else
      ok "反证：注释掉 System.getenv(\"PPF_BUILD_STAMP\") 并返回空串 → 判红"
    fi
    if has_literal "$tmp/build-commented-stamp.kts" 'buildConfigField("String", "BUILD_STAMP"'; then
      ok "对照：注释副本仍保留 buildConfigField 行，红的只是 getenv 断言"
    else
      ko "反证副本意外丢了 buildConfigField 行，红的不是 getenv 断言"
    fi
    remove_seg apps/ios/project.yml 'Add :PPassBuildStamp string' >"$tmp/project-no-add.yml"
    if ios_has_add "$tmp/project-no-add.yml"; then
      ko "反证：删掉 iOS 的 Add 行后检查仍通过"
    else
      ok "反证：删掉 iOS 的 Add 行 → 判红"
    fi
    sed '/PlistBuddy -c "Add :PPassBuildStamp string/ s/^\( *\)/\1# /' apps/ios/project.yml >"$tmp/project-commented-add.yml"
    if ios_has_add "$tmp/project-commented-add.yml"; then
      ko "反证：注释掉 iOS 的 Add 行后检查仍通过"
    else
      ok "反证：注释掉 iOS 的 Add 行 → 判红"
    fi
    remove_seg apps/ios/project.yml 'tr -d' >"$tmp/project-no-tr.yml"
    if ios_has_trim "$tmp/project-no-tr.yml"; then
      ko "反证：删掉 tr -d 后检查仍通过"
    else
      ok "反证：删掉 tr -d → 判红"
    fi
    remove_seg apps/ios/project.yml 's/^[[:space:]]*//' >"$tmp/project-no-lead.yml"
    if ios_has_trim "$tmp/project-no-lead.yml"; then
      ko "反证：删掉首部 trim 后检查仍通过"
    else
      ok "反证：删掉首部 trim → 判红"
    fi
    remove_seg apps/ios/project.yml 's/[[:space:]]*$//' >"$tmp/project-no-trail.yml"
    if ios_has_trim "$tmp/project-no-trail.yml"; then
      ko "反证：删掉尾部 trim 后检查仍通过"
    else
      ok "反证：删掉尾部 trim → 判红"
    fi
    # 注释掉真正带 trim 的那一行（trim 只剩在注释里）：注释行不算数，必须判红。
    sed '/tr -d/ s/^\( *\)/\1# /' apps/ios/project.yml >"$tmp/project-commented-trim.yml"
    if ios_has_trim "$tmp/project-commented-trim.yml"; then
      ko "反证：注释掉真正带 trim 的行后检查仍通过"
    else
      ok "反证：注释掉真正带 trim 的行 → 判红"
    fi
    # 删掉或注释掉 HomeScreen.kt 的 appVersionLine() 调用与空/非空分支后必须判红。
    remove_seg "$home_kt" 'value = appVersionLine()' >"$tmp/home-no-call.kt"
    refute_literal "$tmp/home-no-call.kt" 'value = appVersionLine()' "删掉 appVersionLine() 调用"
    comment_kt_line "$home_kt" 'value = appVersionLine()' >"$tmp/home-commented-call.kt"
    refute_literal "$tmp/home-commented-call.kt" 'value = appVersionLine()' "注释掉 appVersionLine() 调用"
    if has_literal "$tmp/home-commented-call.kt" 'BuildConfig.BUILD_STAMP'; then
      ok "对照：注释调用副本仍保留 appVersionLine 定义，红的只是调用断言"
    else
      ko "反证副本意外丢了 BuildConfig.BUILD_STAMP，红的不是调用断言"
    fi
    remove_seg "$home_kt" 'if (buildStamp.isBlank())' >"$tmp/home-no-blank.kt"
    refute_literal "$tmp/home-no-blank.kt" 'if (buildStamp.isBlank())' "删掉 buildStamp.isBlank() 分支判断"
    comment_kt_line "$home_kt" 'if (buildStamp.isBlank())' >"$tmp/home-commented-blank.kt"
    refute_literal "$tmp/home-commented-blank.kt" 'if (buildStamp.isBlank())' "注释掉 buildStamp.isBlank() 分支判断"
    remove_seg "$home_kt" '"$versionName ($versionCode)"' >"$tmp/home-no-empty-fmt.kt"
    refute_literal "$tmp/home-no-empty-fmt.kt" '"$versionName ($versionCode)"' "删掉空 stamp 分支版本串"
    if has_literal "$tmp/home-no-empty-fmt.kt" '"$versionName ($versionCode) $buildStamp"'; then
      ok "对照：删掉空 stamp 版本串仍保留非空分支，两者未互相掩盖"
    else
      ko "反证副本意外丢了非空 stamp 分支"
    fi
    comment_kt_line "$home_kt" '"$versionName ($versionCode)"' >"$tmp/home-commented-empty-fmt.kt"
    refute_literal "$tmp/home-commented-empty-fmt.kt" '"$versionName ($versionCode)"' "注释掉空 stamp 分支版本串"
    remove_seg "$home_kt" '"$versionName ($versionCode) $buildStamp"' >"$tmp/home-no-stamped-fmt.kt"
    refute_literal "$tmp/home-no-stamped-fmt.kt" '"$versionName ($versionCode) $buildStamp"' "删掉非空 stamp 分支版本串"
    refute_literal "$tmp/home-no-stamped-fmt.kt" '$buildStamp' '删掉非空 stamp 分支后的 $buildStamp'

    # 6) #1890 回归：has_literal 走的是「读完整输入」的路径，大文件里真实存在的字面量必须判绿。
    #    旧写法（管道喂 grep -q + pipefail）在 38KB 以上必假红——下面两对就是那个假红的判据。
    check_large() { # <file> <该文件里一定有的字面量>
      local size
      size="$(wc -c <"$1" | tr -d ' ')"
      if has_literal "$1" "$2"; then ok "大文件不假红：$1（${size} 字节）"; else ko "大文件假红：$1（${size} 字节）里明明有「$2」"; fi
      if has_literal "$1" 'zzz-1890-这个字面量不存在'; then ko "反证：$1 里不存在的字面量被判成有"; else ok "反证：$1 里不存在的字面量 → 判红"; fi
    }
    check_large AGENTS.md 'just doctor'
    check_large "$home_kt" 'BuildConfig.BUILD_STAMP'

    exit "$fail"

# 文案按端拆分（#1302）：key 住对文件、各消费方查得到（含反证自测）。发版判定侧的自测在 version-bump-i18n-test。
i18n-split-check:
  python3 tools/check-i18n-split.py --self-test > /dev/null
  python3 tools/check-i18n-split.py
  @echo "ok: 文案 key 按端归属正确"

# #1302 发版判定的自测（#1500）：改一句文案只要求文案所在的那端涨号。放进 flow-tests，
# 由 CI 的 flow-tests job 一起跑。
version-bump-i18n-test:
  @bash tools/test-version-bump-i18n.sh

# 版本号 bump 的自测（#914）：漂移拒绝、各端同步、versions.json 未知键保留（带反证）。
# 要 Rust —— bump 用 `cargo update -w` 同步两个 workspace 的 lock。
bump-version-test:
  @bash tools/test-bump-version.sh

dead-i18n-test:
  @bash tools/test-check-dead-i18n.sh

# 流程与发版闸门禁的自测：本地 ci / ci-docs 与 CI（ci-docs.yml 的 flow-tests job）共用这一份清单。
doc-anchors-test:
  @bash tools/test-check-doc-anchors.sh

changelog-section-test:
  @bash tools/test-changelog-section.sh

flow-tests: doc-anchors-test changelog-section-test hooks-test flow-engine-test flow-ci-review-test flow-gate-status-test macos-runner-test main-red-test ci-lane-invariants-test ui-regress-judge-test ci-download-resilience-test bump-version-test version-bump-i18n-test clean-local-builds-test e3-test dead-i18n-test desktop-dead-components-test pr-watch-test
  @bash tools/test-ci-paths.sh
  @python3 -B -I tools/test-ci-impact.py
  @echo "==> flow-tests: green ✅"

# #1468 的 lane 不变量：五条 lane 有 push: branches [main]、push 上 cancel-in-progress 为 false、
# 四端 PR 对称门禁（Windows 3 job 不跳过 pull_request）；读 workflow YAML（缺 PyYAML 判红，不 SKIP），带变异反证。
ci-lane-invariants-test:
  @bash tools/test-ci-lane-invariants.sh

# #1595 的外部下载韧性不变量：跑 Gradle 的每条 workflow 都接发行版缓存且只在成功时保存，
# fetch-ffmpeg.sh 的下载带重试且 sha256 校验还在；读实际文件，带变异反证。
ci-download-resilience-test:
  @bash tools/test-ci-download-resilience.sh

# QA-03 文档快车道：只跑文档域的门禁，不编 Rust。
#
# 为什么要这条：`ci` 里的 fmt/lint/test 是全量 Rust 构建 + clippy + nextest，
# 而改一个字的卡也要跑一遍——远端 CI 反倒早就按 paths 分好了 lane
# （纯文档提交只点起 ci-docs）。本地缺的就是同一件事。
#
# 门禁挑选（tools/flow/flow.py 的 pick_gates，#1750）把纯文本改动分到了秒级的
# `just md-check`；本条是流程文件（justfile / tools/just/*.just / issue 与 PR 模板 / AGENTS.md；workflow 另加 actionlint）的聚合入口。
#
# ⚠️ 只在这次改动**一行 Rust/Kotlin/前端都没动**时用它。碰了代码就跑 `just ci`，
# 别拿这条快车道当省事的借口——`ci` 的依赖列表一个都没减。
ci-docs: md-check doc-anchors-check token-check shell-vars-check identity-check supply-chain-check build-stamp-check flow-tests heavy-lock-test
  @echo "==> docs lane: green ✅（注意：本条不含 fmt/lint/test，动了代码必须跑 just ci）"

# 重编译锁入口的判据测试：可重入、串行、超时
heavy-lock-test:
  @bash tools/test-heavy-lock.sh
