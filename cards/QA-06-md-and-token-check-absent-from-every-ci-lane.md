# QA-06 md-check / token-check 不在任何 CI lane 里——只靠「人记得跑 just ci」　级别 L1

状态：🟥 挂号
级别：L1（只动 workflow/门禁配置）
关联：从 [QA-05](QA-05-md-check-blind-to-mid-row-hard-wrap.md) 分出（核对本 PR 该点起哪条 lane 时撞见）。与 QA-05 是**两件事、两个修法**：QA-05 改判据（`check-markdown-tables.py` 抓不到行中硬换行），本卡改覆盖（脚本压根没上 CI）；`token-check` 与 QA-05 无关。

## 挂号段（发现时 30 秒填完；🟥 状态只许有这三行，不可被接）

- 现象：`justfile` 里 `ci-docs: queue-check md-check token-check`、
  `ci: fmt lint test arch-check queue-check md-check token-check`，但
  `grep -rn 'md-check\|token-check\|check-markdown-tables\|check-token-drift'
  .github/workflows/` **零命中**。`ci-docs.yml` 只有两个 step
  （`check-queue-sync.sh` + `test-queue-archive-gate.sh`），所以
  `tools/check-markdown-tables.py`（md 表格被切断）与
  `tools/check-token-drift.py`（`tokens.css` ↔ `tokens.json` 漂移）
  **在 PR 与 push 上都没有任何门禁**，只存在于本地 recipe。
  讽刺的是 `ci-docs.yml` 自己头部写的开 lane 理由就是「如果只有本地约束，
  就又回到『靠人记得跑 just ci』，与它想解决的问题相同」——把 `queue-check`
  搬上了 CI，却把同一条 recipe 里的另外两条留在本地，同一条推理没走完。
- 发现场景：2026-09-17，DOC-02/QA-05 的 PR（#66）合并后核对「这个 PR 该
  点起哪条 lane、预期什么结果」时，逐个读 `.github/workflows/*.yml` 的
  触发段发现。
- 严重度猜测：中。与 QA-05 叠加后是**零防护**：md 表格完整性在远端既没有
  判据（QA-05 的盲区）也没有执行（本卡）。`token-check` 那条更直接——
  DESK-15 专门为「设计 token 漂移」建的门禁，目前同样只在本地。

## 可接段（🟥→⬜ 由派活时补满，缺字段=不可接）

context:（修法看着只是往 `ci-docs.yml` 加两个 step，但有两处要想清楚：
  ⒜ **paths 不匹配**：`ci-docs.yml` 的 paths 是 `docs/QUEUE.md` + `cards/**`
     + 两个 queue 脚本；而 md-check 扫的是全仓 `*.md`（291 个文件）、
     token-check 看的是 `assets/design/tokens.{css,json}`。直接塞进去，
     改 `docs/RELEASING.md` 或 `assets/design/` 的 PR 仍然不触发门禁——
     覆盖面得跟着判据的作用域一起定，否则是第二个「看着有、实际不跑」。
  ⒝ **反证要求**：AGENTS.md 红线 3 要求故障类判据带反证。加 step 时应同时
     证明它真会红——`ci-docs.yml` 已有先例（「反证与门禁同生共死」那个 step）。）
问题:
期望行为:
验收标准:
范围:
阻塞与依赖:无。

## 实施记录（做完填）
