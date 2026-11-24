#!/usr/bin/env bash
# 反证与自测：证明 tools/check-doc-anchors.py 在各层断链/断锚时真正变红，加回有效目标时复绿。
#
# 变异场景：
#   1. Tier 1: 正常现行文档 → 必须绿
#   2. Tier 1: Markdown 相对链接指向不存在文件 → 必须红（反证）
#   3. Tier 1: 反引号仓库真实路径不存在（如 `tools/nonexistent_script.sh`） → 必须红（反证）
#   4. Tier 1: 反引号 `just nonexistent-recipe` 未在 justfile 定义 → 必须红（反证）
#   5. Tier 1: 模板占位符（`<...>`、`*`、`...`）和外部路径不误报 → 必须绿
#   6. Tier 2: 历史决策文档 Markdown 相对链接正常 → 必须绿
#   7. Tier 2: 历史决策文档 Markdown 相对链接断链 → 必须红（反证）
#   8. Tier 2: 历史决策文档中的旧代码路径变更不卡门禁 → 必须绿
#   9. Tier 3: 官网 blog 正常相对链接 → 必须绿
#  10. Tier 3: 官网 blog 断链 → 必须红（反证）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$ROOT/tools/check-doc-anchors.py"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/fixture_repo"
mkdir -p "$FIXTURE"

# 构建最小测试仓库夹具
mkdir -p "$FIXTURE/tools" "$FIXTURE/docs/runbook" "$FIXTURE/docs/decisions" "$FIXTURE/site/src/content/blog" "$FIXTURE/site/public/icons"

cat > "$FIXTURE/justfile" <<'EOF'
default:
    @echo "default"
test-recipe:
    @echo "test"
EOF

cat > "$FIXTURE/tools/real_tool.sh" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$FIXTURE/docs/runbook/target.md" <<'EOF'
# Target Document
EOF

cat > "$FIXTURE/site/public/icons/logo.svg" <<'EOF'
<svg></svg>
EOF

fail_count=0

pass() {
    printf '  ✅ %s\n' "$1"
}

fail() {
    printf '  ❌ %s\n' "$1"
    fail_count=$((fail_count + 1))
}

echo "=== 运行 check-doc-anchors.py 反证与自测 ==="

# 场景 1: Tier 1 正常现行文档
cat > "$FIXTURE/AGENTS.md" <<'EOF'
# AGENTS
See [Runbook Target](docs/runbook/target.md).
Run `tools/real_tool.sh` and `just test-recipe`.
Ignore placeholders like `tools/<template>.sh`, `foo/*`, `foo...`, and `release/v1.0`.
EOF

if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >/dev/null 2>&1; then
    pass "场景 1: Tier 1 正常现行规范绿"
else
    fail "场景 1: Tier 1 正常现行规范应绿但红"
fi

# 场景 2: Tier 1 相对链接断链变红
cat > "$FIXTURE/AGENTS.md" <<'EOF'
# AGENTS
Broken link: [Missing](docs/runbook/nonexistent.md).
EOF

if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >/dev/null 2>&1; then
    fail "场景 2: Tier 1 相对链接断链应红但绿（反证失效）"
else
    pass "场景 2: Tier 1 相对链接断链变红（反证成功）"
fi

# 场景 3: Tier 1 反引号不存在的仓库路径变红
cat > "$FIXTURE/AGENTS.md" <<'EOF'
# AGENTS
Invalid script: `tools/nonexistent_script.sh`.
EOF

if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >/dev/null 2>&1; then
    fail "场景 3: Tier 1 仓库路径失效应红但绿（反证失效）"
else
    pass "场景 3: Tier 1 仓库路径失效变红（反证成功）"
fi

# 场景 4: Tier 1 反引号不存在的 just recipe 变红
cat > "$FIXTURE/AGENTS.md" <<'EOF'
# AGENTS
Invalid recipe: `just non-existent-command`.
EOF

if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >/dev/null 2>&1; then
    fail "场景 4: Tier 1 just recipe 失效应红但绿（反证失效）"
else
    pass "场景 4: Tier 1 just recipe 失效变红（反证成功）"
fi

# 场景 5: Tier 1 模板占位符与放行路径不误报
cat > "$FIXTURE/AGENTS.md" <<'EOF'
# AGENTS
Valid placeholders: `tools/<tool-name>.sh`, `apps/*`, `crates/...`, `release/v2026.11`.
Valid just: `just test-recipe`.
EOF

if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >/dev/null 2>&1; then
    pass "场景 5: Tier 1 模板占位符放行正常"
else
    fail "场景 5: Tier 1 模板占位符被误判报红"
fi

# 场景 6: Tier 2 正常历史决策 Markdown 链接
cat > "$FIXTURE/docs/decisions/2026-01-01-test.md" <<'EOF'
# Decision
Link to [Target](../runbook/target.md).
Historical dead path `crates/ancient/legacy.rs` should NOT be checked.
EOF

if python3 "$CHECKER" --tier 2 --root "$FIXTURE" >/dev/null 2>&1; then
    pass "场景 6: Tier 2 正常历史决策 Markdown 链接绿且忽略代码路径"
else
    fail "场景 6: Tier 2 正常历史决策应绿但红"
fi

# 场景 7: Tier 2 历史决策链接断链变红
cat > "$FIXTURE/docs/decisions/2026-01-01-test.md" <<'EOF'
# Decision
Broken relative link [Broken](../missing.md).
EOF

if python3 "$CHECKER" --tier 2 --root "$FIXTURE" >/dev/null 2>&1; then
    fail "场景 7: Tier 2 历史决策断链应红但绿（反证失效）"
else
    pass "场景 7: Tier 2 历史决策断链变红（反证成功）"
fi

# 场景 8: 网站文档正常时，不检查依赖与生成目录里的断链。
for dir in node_modules dist .astro; do
    mkdir -p "$FIXTURE/site/$dir/nested"
    printf '[Missing](missing.md)\n' > "$FIXTURE/site/$dir/nested/README.md"
done
cat > "$FIXTURE/site/src/content/blog/post.md" <<'EOF'
# Blog Post
See image [Icon](/icons/logo.svg) and route [Blog](/blog/other).
EOF

if python3 "$CHECKER" --tier 3 --root "$FIXTURE" >/dev/null 2>&1; then
    pass "场景 8: Tier 3 正常 site Markdown 链接绿"
else
    fail "场景 8: Tier 3 正常 site Markdown 链接应绿但红"
fi

# 场景 9: Tier 3 断链变红
cat > "$FIXTURE/site/src/content/blog/post.md" <<'EOF'
# Blog Post
Broken link to [Nonexistent](relative-missing.md).
EOF

if python3 "$CHECKER" --tier 3 --root "$FIXTURE" >"$TMP/site-broken.log" 2>&1; then
    fail "场景 9: Tier 3 断链应红但绿（反证失效）"
elif grep -Fq 'broken link -> relative-missing.md' "$TMP/site-broken.log"; then
    pass "场景 9: Tier 3 断链变红（反证成功）"
else
    cat "$TMP/site-broken.log"
    fail "场景 9: Tier 3 没有报出网站文章里的断链"
fi

# 场景 10: 干净检出不需要本机专用配置。
cat > "$FIXTURE/AGENTS.md" <<'EOF'
Local configuration: `.claude/settings.local.json`.
EOF
if python3 "$CHECKER" --tier 1 --root "$FIXTURE" >"$TMP/local-config.log" 2>&1; then
    pass "场景 10: 本机配置不要求出现在干净检出"
else
    cat "$TMP/local-config.log"
    fail "场景 10: 本机配置被误判为仓库文件"
fi

# 场景 11: Windows 非 UTF-8 输出编码不能改变检查的退出状态。
cat > "$FIXTURE/AGENTS.md" <<'EOF'
Run `tools/real_tool.sh`.
EOF
if PYTHONIOENCODING=gbk:strict python3 "$CHECKER" --tier 1 --root "$FIXTURE" >"$TMP/gbk.log" 2>&1; then
    pass "场景 11: GBK 输出下有效文档仍为绿"
else
    cat "$TMP/gbk.log"
    fail "场景 11: GBK 输出下有效文档应绿但红"
fi

# 场景 12: 命令清单读取失败或为空时，一级检查不能报绿。
mkdir -p "$TMP/fake-bin"
printf '#!/bin/bash\nexit "${FAKE_JUST_EXIT:-0}"\n' > "$TMP/fake-bin/just"
chmod +x "$TMP/fake-bin/just"
for rc in 0 1; do
    if FAKE_JUST_EXIT="$rc" PATH="$TMP/fake-bin:$PATH" python3 "$CHECKER" --tier 1 --root "$FIXTURE" >"$TMP/just-summary.log" 2>&1; then
        fail "场景 12: 无法取得 just 命令清单时错误放行（just 退出 ${rc}）"
    elif grep -Fq 'cannot validate just recipes' "$TMP/just-summary.log"; then
        pass "场景 12: 无法取得 just 命令清单时报错（just 退出 ${rc}）"
    else
        cat "$TMP/just-summary.log"
        fail "场景 12: 没有说明 just 命令清单读取失败"
    fi
done

if [ "$fail_count" -gt 0 ]; then
    echo "❌ $fail_count 个场景失败"
    exit 1
fi

echo "✅ 全部 12 个反证与自测场景全绿！"
