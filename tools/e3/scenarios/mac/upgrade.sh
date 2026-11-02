# 冒烟①（M-up）：上一版正式包 → 覆盖装候选构建：身份（NodeId）、配对、照片数不变，服务不崩。
#
# TODO（排期 4b）：本机 ~/Applications/P-Pass.app 是正式包、挂着用户的库；开发版与正式版共用 bundle id、
# LaunchAgent 与数据目录（见 tools/mac-dev.sh 的互斥说明），覆盖安装会替换用户在用的那一份。
# `--ephemeral` 桩是内存身份、重启即换 NodeId，测不了升级。等开发版独立身份（.dev 变体）落地后：
#   setup  装上一版 .dev 包 → testclient 配对 → 备份 N 张 → 记 NodeId / 配对数 / 照片数（IPC）
#   act    覆盖装候选 .dev 包 → 等服务就绪 → 再采同一组数据
#   judge  三项不变、日志无 panic
#   counter 覆盖装后删掉身份文件再启动 ⇒ NodeId 变化、必须判红
# 在那之前本场景记 SKIP（不是 PASS）。
DESC="上一版→候选覆盖升级后身份/配对/计数不变（待 .dev 变体，当前 SKIP）"

setup() {
  echo "跳过：等开发版独立身份（排期 4b），否则会覆盖本机正式包与用户的库"
  return 77
}
act() { :; }
judge() { return 1; }
