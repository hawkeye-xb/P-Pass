# iOS 工程生成、资源生成、测试与界面回归配方

# iOS（#887）：apps/ios/project.yml → XcodeGen 生成 PPass.xcodeproj（不入库）。
# 需要 macOS + Xcode + xcodegen（brew install xcodegen）+ jq。
ios-gen:
  cd apps/ios && xcodegen generate

# iOS i18n（#316）：assets/i18n/*.json（#1302 起只放跨端 msg_key）逐字节拷进 apps/ios/PPass/Resources/i18n/。
# 改 i18n 要同步四个消费者（清单见 apps/ios/PPass/I18n/DiagText.swift）；--check 只比较不拷。
ios-sync-i18n *args:
  bash tools/ios/sync-i18n.sh {{args}}

# iOS 设计 token（#344）：assets/design/tokens.json → apps/ios/PPass/Design/Tokens.generated.swift。
# 改了 tokens.json 就跑一次并提交生成物；ci-ios 用 --check 逐字节比对，不同步就红。
ios-tokens:
  python3 tools/ios/gen-tokens.py

# iOS App 图标三态 + 启动屏图标（#941）：docs/design/2026-08-11-icon-v1 的定稿 SVG → Assets.xcassets。需要 rsvg-convert + Pillow。
ios-icons:
  python3 tools/ios/gen-app-icon.py

# iOS 界面文案（#315）：Android strings.xml → apps/ios/PPass/Resources/{en,zh-Hans}.lproj/Localizable.*。
# #1302：只读 strings.xml（两部手机共用的句子）；Android 独有文案在 strings_android_only.xml，不进 iOS。
# Android 改了文案就跑一次并提交；ci-ios 用 --check 逐字节比对。iOS 独有说法写在同目录的 IOS.strings。
ios-strings *args:
  python3 tools/ios/gen-strings.py {{args}}

# iOS 逐屏截图（#315）：演示数据，按「场景 × 路由」冷启动截图，输出 apps/ios/build/screenshots（不入库）。
ios-screenshots *args:
  bash tools/ios/screenshots.sh {{args}}

# iOS 单元测试：生成工程 → xcodebuild test。本机有真机时优先真机，CI 或无真机时用模拟器。
# 真机只跳过 tools/ios/host-only-tests.txt 里明确依赖宿主源文件的测试；FFI 的 tool-hosted testing 也明确延期到 CI。
# 与 ci-ios.yml 同一组：App 测试 → 隐私清单 → TransportFFITests（本机隔离 daemon，
# daemon 用 debug 构建，与 CI 一致）。少跑 FFI 那步，Rust 侧改了 FFI 字段本地看不出来（11-02 #1304）。
# #1378：just ios-test --lang en|zh 只跑 App 测试并指定测试语言（本机模拟器多是中文、CI 是英文；
# 文案改动交卡时 just done 中英各跑一次）。结束时关掉本配方运行期间新开的模拟器（tools/ios/sim.sh shutdown-new）。
ios-test *args:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{ justfile_directory() }}"
  lang=""
  set -- {{args}}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lang) lang="${2:-}"; shift 2 || shift ;;
      *) echo "用法: just ios-test [--lang en|zh]" >&2; exit 2 ;;
    esac
  done
  [ -z "$lang" ] || langargs="$(bash tools/ios/sim.sh lang-args "$lang")"
  source tools/ios/lanes.sh
  # 语言测试必须保留 UIResourceTests 的宿主语言断言，不能因真机分轨跳过整类。
  [ -z "$lang" ] || export PPASS_IOS_FORCE_SIMULATOR=1
  ios_lane_select
  if [ "$PPASS_IOS_LANE" = simulator ] && [ "${CI:-}" != "true" ]; then
    before="$(bash tools/ios/sim.sh booted)"
    trap 'bash tools/ios/sim.sh shutdown-new "$before"' EXIT
  fi
  if [ -n "$lang" ]; then
    # shellcheck disable=SC2086 # 刻意按空格拆成参数
    bash tools/ios/test.sh $langargs
  else
    bash tools/ios/test.sh
    bash tools/ios/privacy-manifest-local.sh
    if ios_lane_is_device; then
      printf 'FFI_DEFERRED=tool-hosted testing requires the host simulator; run in CI\n'
    else
      PPASS_DAEMON_PROFILE=dev bash tools/ios/test-transport-ffi.sh
    fi
  fi

# iOS 界面回归（#1458）：XCUITest 走真实界面、系统弹窗由测试点，按 App 日志逐例判 PASS/FAIL。
# just ios-ui-regress sim|device [--only A,B] [--invert <用例>] [--skip-build]；真机自动持 tools/e3/lock ios，
# 构建在锁外先跑完再持锁（设备锁规矩）。说明见 docs/runbook/ios-ui-regress.md。
ios-ui-regress target *args:
  #!/usr/bin/env bash
  set -euo pipefail
  cd "{{ justfile_directory() }}"
  case "{{target}}" in
    sim) bash tools/ios/ui-regress.sh sim {{args}} ;;
    device)
      # --skip-build 只传一次（#1701/#1709）：用户自带时只持锁跑一条；否则锁外 build-only、锁内 skip-build。
      args='{{args}}'
      case " $args " in
        *" --skip-build "*)
          tools/e3/lock ios bash tools/ios/ui-regress.sh device $args
          ;;
        *)
          bash tools/ios/ui-regress.sh device --build-only $args
          tools/e3/lock ios bash tools/ios/ui-regress.sh device --skip-build $args
          ;;
      esac
      ;;
    *) echo "用法: just ios-ui-regress sim|device [--only A,B] [--invert <用例>] [--skip-build]" >&2; exit 2 ;;
  esac

# iOS 本地 SwiftPM 包（apps/ios/Packages/*/Package.swift）逐个在模拟器上测（#345）。没有包时直接通过。
ios-test-packages:
  bash tools/ios/test-packages.sh

# iOS 界面回归的判定自测（#1458/#1701）：只认本例日志、通过行按顺序出现；几秒、不要设备。
ui-regress-judge-test:
  @bash tools/ios/test-ui-regress-judge.sh

# workflow 不得再用已停用的 macOS runner
macos-runner-test:
  @bash tools/test-macos-runner.sh
