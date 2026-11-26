# 工作区安装、自检、本地磁盘清理与同步配方

# Install toolchain checks + git hooks.
#
# 工具链部分：rustup 钉的 toolchain（见 rust-toolchain.toml）+ cargo-nextest
# / cargo-deny。git hooks 部分：用 pre-commit 把仓内 .pre-commit-config.yaml
# 的门禁（当前是 gitleaks）装进 .git/hooks/pre-commit。
#
# QA-10：pre-commit 可执行文件不一定在 PATH 上（比如装在用户级 Python 的
# Scripts 目录），PATH 上那个还可能是坏的（装了包但环境坏了）。所以按
# pre-commit（要求存在且 --version 能跑通）→ python3 -m pre_commit →
# python -m pre_commit 的顺序探测，三者皆不可用就报错退出——装不上不许
# 静默跳过。
# gitleaks 是 language: system 的本机可执行文件，必须在 PATH 上 hook 才跑
# 得动；它缺了不挡 hook 安装，但会让每次提交都硬失败，所以装完 hook 后单独
# loud-check 一次，缺了打 WARNING 并给出安装指引。
# 本地提交拦截（核心 + 范围，见 docs/runbook/local-hooks.md）不依赖 pre-commit 框架：
# tools/hooks/install.sh 把 core.hooksPath 指向 git 公共目录里的转发器，转发器先跑上面装进
# .git/hooks/ 的 hook，再跑 HEAD 里的 tools/hooks/。框架看到 core.hooksPath 会拒绝安装，
# 所以先 --release 让路；框架装不上也照样装本拦截，再报错退出。
setup:
  @echo "==> Checking Rust toolchain..."
  rustup show
  @echo "==> Installing cargo-nextest..."
  cargo install cargo-nextest --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing cargo-deny..."
  cargo install cargo-deny --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing just..."
  @echo "  (just is already running this file — you have it! 🎉)"
  @echo "==> Installing git hooks (pre-commit)..."
  @bash tools/hooks/install.sh --release
  @if command -v pre-commit >/dev/null 2>&1 && pre-commit --version >/dev/null 2>&1; then \
    pre-commit install; \
  elif python3 -m pre_commit --version >/dev/null 2>&1; then \
    python3 -m pre_commit install; \
  elif python -m pre_commit --version >/dev/null 2>&1; then \
    python -m pre_commit install; \
  else \
    echo "ERROR: pre-commit not found — git hooks were NOT installed." >&2; \
    echo "  Tried: pre-commit on PATH (exists AND --version works), python3 -m pre_commit, python -m pre_commit." >&2; \
    echo "  Fix: pip install pre-commit   then re-run: just setup" >&2; \
    bash tools/hooks/install.sh; \
    exit 1; \
  fi
  @echo "==> Installing local commit gate (core + scope)..."
  @bash tools/hooks/install.sh
  @if command -v gitleaks >/dev/null 2>&1; then \
    echo "  gitleaks found in PATH ($(command -v gitleaks))"; \
  else \
    echo "WARNING: gitleaks not found in PATH." >&2; \
    echo "  The installed hook (gitleaks protect --staged) will FAIL on every commit." >&2; \
    echo "  Install it: https://github.com/gitleaks/gitleaks#installing" >&2; \
  fi

# 开工前环境自检（worker 与 owner 都先跑）：位置（主副本 / 卡 worktree、拒绝 Windows 回归克隆）、
# bash 能否真执行、本地提交拦截、gh 读 issue、提交身份白名单、磁盘 ≥ 15G；私仓模式与在线设备只报不判。
# 任一必需项不满足就非 0 退出并打印怎么修。just start 与 owner 各命令开头都会先跑它。
doctor:
  @python3 -B -I tools/flow/flow.py doctor

# Local disk recovery. No arguments only previews; deletion needs --apply plus a scope.
cleanup-local *args:
    bash tools/clean-local-builds.sh {{args}}

# QA-13: fetch + automatic reclamation, the moment the info is freshest.
# GitHub deletes a PR's head branch on merge, so right after --prune the
# merged-and-done worktrees are exactly the ones whose upstream vanished;
# removal still passes every existing guard (current worktree / uncommitted
# changes / not-merged / active build / fail-closed probe). Local-only by
# construction: fetch is read-only, deletion touches local dirs only.
# Scope note: `--worktrees`, not `--all` — auto-deleting the CURRENT
# worktree's target/ would force a full rebuild on every pull; cache
# reclamation for kept worktrees stays manual (`just cleanup-local
# --apply --targets`), which is a deliberate cost choice, not an oversight.
sync:
    git fetch --prune origin
    bash tools/clean-local-builds.sh --apply --worktrees

# Safety integration test; it creates and destroys only a temporary Git repository.
clean-local-builds-test:
    bash tools/test-clean-local-builds.sh
