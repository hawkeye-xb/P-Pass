# QA-02 归档门禁变异 C 空转：QUEUE 分区七成为末节后反证从未真正执行　级别 L1

状态：🟡 代码完成待你过目（2026-09-17，本 PR，分支 `test/qa02-queue-archive-gate-mutation-c`）
级别：L1（本地脚本，无真机）
关联：从 NET-16 分出（做卡时跑 `just ci` 撞见 traceback）

## 挂号段（发现时 30 秒填完；🟥 状态只许有这三行，不可被接）

- 现象：`tools/test-queue-archive-gate.sh` 变异 C 的 python 段第 5 行
  `j = next(k for k, l in enumerate(lines[i + 1:], i + 1) if l.startswith("## "))`
  在 `docs/QUEUE.md` 里抛 `StopIteration`——`## 七、相关文档指路` 现在是
  **最后一个分区**，它后面没有任何 `## ` 标题可找。python 非零退出 →
  `$TMP/c.md` 根本没被写出；但脚本 `set -uo pipefail`（无 `-e`）继续跑，
  `expect fail "$TMP/c.md"` 拿不存在的文件喂门禁，门禁自身报错也是非零
  退出 → 被当成「分区被删 → fail（符合期望）」。**门禁的反证在空转**：
  变异 C 从未真正测过「删分区」这个漂移模式，stderr 的 Traceback 是
  唯一露出来的痕迹，而 `just ci` 整条绿。
- 发现场景：2026-09-17 做 NET-16，`just ci` queue-check 步 stderr 打出
  `File "<stdin>", line 5, in <module> / StopIteration`（日志
  `/tmp/net16_ci2.log:26`），紧随其后的 ✅ 照打、exit 0。
  引入时点：`1968008`（2026-09-16 QUEUE 重构，11 分区→8 分区，七从
  中间挪到末尾），当天起变异 C 即坏，两天无人察觉。
- 严重度猜测：中。「3/3 归档出口反证成立」这句结论有一条是假的；
  删分区漂移从此无防护。

## 可接段（🟥→⬜ 由派活时补满，缺字段=不可接）

context: 根因如上。`check-queue-sync.sh` 的 `EXPECTED` 分区集合本身没错、
  判定逻辑也没错——坏的是反证生成器的相对定位假设（「目标分区后面还有
  分区」）。修法建议：变异 C 改删一个**非末节**分区（如「六、backlog」，
  用 `num(h) == "六"` 定位），并把三个变异 python 段的非零退出纳入
  `expect` 前置断言（生成器挂了=脚本直接红，禁止吞码）。
问题:反证脚本自身异常被 `|| got=fail` 的巧合语义掩盖，门禁退化静默。
期望行为:变异生成器失败 → `test-queue-archive-gate.sh` 非零退出且指明
  哪个变异挂；`just ci` 随之变红；变异 C 真正执行「删一个分区」的语义。
验收标准:
- [x] 反证的反证 [E2]：临时给 `check-queue-sync.sh` 加一条恒真短路
      （模拟门禁瞎掉），变异 C 必须让脚本变红；恢复复绿——证明 C 不再
      依赖「文件不存在也非零」的巧合。
      **实测（2026-09-17）**：PYGATE 顶部插 `sys.exit(0)` 后脚本退出码 1——
      变异 A/B 由「pass，期望 fail」真红；变异 C 经 1/4 方向仍红（删「六、
      backlog」区后 MOB-07 失去在 QUEUE 的唯一登记，`missing-from-queue`），
      即 C 的红来自真副本喂真门禁，不再是生成器崩溃的副产品。`git
      checkout` 恢复后复跑退出码 0。
- [x] `bash tools/test-queue-archive-gate.sh` 退出码 0 且 **stderr 无
      Traceback** [E1]（新增断言：`2>&1 | grep -q Traceback && exit 1`）。
      **实测**：退出码 0，`grep -c Traceback` = 0，3/3 反证全按期望变色。
- [ ] `just ci` 全绿 [E1]。**沙箱无 Rust 工具链无法本机跑**——本分支推上
      PR 后由 ci-rust/ci-docs lane 闭环（queue-check 属 ci-docs 域，受影响
      lane 只有 ci-docs）。
范围:只准动 `tools/test-queue-archive-gate.sh`。不准动
  `check-queue-sync.sh` 的判定语义与 `docs/QUEUE.md` 分区结构。
  **核实**：`git diff origin/main..HEAD` 只有 `tools/test-queue-archive-gate.sh`
  一个文件（含可执行位不变）。
阻塞与依赖:无。

## 实施记录（做完填）

2026-09-17（本 PR，分支 `test/qa02-queue-archive-gate-mutation-c`）：

**修法**（照卡面建议，两处）：

1. **变异 C 改删非末节分区**：目标从「七、相关文档指路」（末节，后面没有
   下一个 `## ` 标题，`next()` 抛 StopIteration）改为「六、backlog」
   （后面有「七、」，定位必中）。删六区同时真实触发两条门禁路径：3/4 的
   `section-drift`（分区集合少「六」）与 1/4 的 `missing-from-queue`
   （MOB-07 的唯一登记行就在六区）。
2. **生成器失败禁止吞码**（新增 `mutated_or_die` 前置断言 + python 段包
   `if ! ... exit 1`）：三个变异各自的生成器非零退出或副本缺失，脚本立即
   以非零退出并指明哪个变异——`expect` 的「文件不存在 → 门禁报错也非零
   → 碰巧算 fail」巧合语义从此拿不到不存在的文件。

**验证**（全部真跑，非纸面）：

- `bash -n` 语法过；修复后脚本退出码 0，Traceback 0 条，3/3 按期望变色。
- 变异 C 副本单独喂真门禁：判定路径实测为 `FAIL section-drift: 分区序号
  集合变了 / 实际 ['〇','一','二','三','四','五','七']`——是门禁在判，
  不是脚本在崩。
- 反证的反证：`check-queue-sync.sh` 的 PYGATE 顶部临时插 `sys.exit(0)`
  → 脚本退出码 1（A/B 真红、C 仍红）；恢复复绿。`git diff` 确认
  `check-queue-sync.sh` 与 `docs/QUEUE.md` 零改动。
- 提交身份过 `tools/check-commit-identity.sh`（lizhaowen 白名单内）。

**环境偏差记录（不掩盖）**：本卡交付在 agent 沙箱执行，该环境无 Rust
工具链与 `just`，故验收标准「`just ci` 全绿」未在本地完成——本分支只动
bash/python 脚本，受影响 CI 域为 ci-docs；推 PR 后由远端 lane 闭环。
沙箱挂载不保留可执行位，已用 `git update-index --chmod=+x` 在索引层恢复，
diff 中无 mode 变化。
