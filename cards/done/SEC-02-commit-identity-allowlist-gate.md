# SEC-02 提交身份没有任何门禁——只靠每台机器自己配得对　级别 L1

状态：✅ 代码完成，全部验收项闭环，待归档（commit b19d6c1e / PR #70）
级别：L1（只动门禁脚本 + 一条新 workflow，不碰产品代码）
关联：从 SEC-01 分出——SEC-01 是清理已经发生的越界，本卡是防止再次发生。两件事、两个修法。
（此处刻意**不写相对链接**：SEC-01 的卡还在它自己的 PR 分支上、尚未进 main，写了链接会被 `queue-check 4/4` 判为悬空——这正是 QA-03 挂号的那类问题。SEC-01 合入后再补链接。）

## 挂号段

- 现象：仓库对「谁能提交」零约束。2026-08-26 有 6 个提交带着不在身份白名单内的 author/committer 进了 main，无论 PR 还是 push 都没有任何门禁报警，直到三周后人工核查 `git log --format='%an <%ae>'` 才发现。
- 发现场景：2026-09-17 做 SEC-01 的历史改写时，追问「为什么当时没拦住」。
- 严重度猜测：中高。身份一旦进了公开仓的提交历史就**不可撤销**——改写历史需要强推全部分支，且 `refs/pull/*` 只读推不动（SEC-01 正卡在这一步）。事后补救的代价远大于事前拦截。

## 可接段

context:
  - **本机 hook 存在但覆盖不到**：`~/.git-templates/hooks/pre-commit` 与 `pre-push` 从 2026-05-18 就在，且已部署到 6 个 personal 仓库。但越界的那 6 个提交来自**另一台机器**——本机 hook 只能约束装了它的机器，这是本地方案的结构性上限。
  - **本机 hook 还有一条是空转的**：原 pre-commit 第 1 条用 `git var GIT_AUTHOR_EMAIL` 取作者邮箱，但 `git var` 只认 `GIT_AUTHOR_IDENT` / `GIT_COMMITTER_IDENT`，不存在 `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` 这两个变量——git 打 usage 到 stderr 并返回空字符串，于是这条检查从写下那天起一直没跑过。第 2、3 条（diff / message）有效，所以问题是「三条里有一条是哑的」，不是整个 hook 无效。
  - **必须是白名单不是黑名单**：黑名单要把「禁止什么」写进仓库，那串字符本身就成了提交内容——为了防泄漏反而主动泄漏一次。白名单只描述允许谁，可安全入库。
  - 全史实测：现有 1065 个提交的 author/committer 全部落在白名单内，加门禁不会把历史判红。

问题:
  任何人在任何机器上用任何身份提交，服务端都不会拒绝。本机 hook 是唯一防线，而它按定义管不到没装它的机器。

期望行为:
  - 服务端：每个 PR、每次进 main 的推送，所有提交的 author 与 committer 都必须在白名单内，否则 CI 红。
  - 本机：pre-commit 拦当前这一条，pre-push 拦所有要推上去的（cherry-pick / rebase 进来的提交不经过 pre-commit）。
  - name 与 email 都要逐字符匹配——只对一半不算过。

验收标准:
  - [x] [E1] `bash tools/test-commit-identity-gate.sh` 六个变异全部符合期望。
  - [x] [E2] **反证真跑**：门禁对 2026-08-26 那 6 个真实越界提交逐条报红（author / committer 两个位置各报一次），不是构造出来的假数据。
  - [x] [E1] 全史 1065 个提交过白名单全绿——不会把既有历史判红。
  - [x] [E1] 本机 hook 四条实测：陌生身份拦 / name 对 email 错拦 / email 对 name 错拦 / 白名单身份放行。
  - [x] [E1] 门禁脚本在 **bash 3.2**（macOS 自带）下可跑——不能出现「本地红 CI 绿」的隐身分歧。
  - [x] [E1] 合并后观察一次真实 PR 上 `CI Identity` lane 变绿——PR #70 上 `CI Identity` **success**，合入 main 后 push lane 同样 success。

范围:
  只准动：`.github/allowed-identities.txt`、`tools/check-commit-identity.sh`、`tools/test-commit-identity-gate.sh`、`.github/workflows/ci-identity.yml`、`justfile`、本卡、`docs/QUEUE.md`。
  **不准动**：任何产品代码、其他 workflow、SEC-01 的卡与分支。

阻塞与依赖:
  - 白名单里是否保留 `dependabot[bot]` 是**策略选择不是安全问题**，需要你拍板（见下）。
  - 本机 hook 的改动在仓库外（`~/.git-templates/hooks/` 与各仓 `.git/hooks/`），不随本 PR 走，已直接部署。

## 实施记录

**服务端（入库部分）**

- `.github/allowed-identities.txt`：白名单，3 个人类身份 + 3 个平台机器人。全文不含任何需要保密的内容。
- `tools/check-commit-identity.sh`：查指定区间内每个提交的 author 与 committer，name+email 逐字符匹配。空白名单判红（空白名单不得等于放行）。
- `tools/test-commit-identity-gate.sh`：六变异反证——A 合法放行 / B author 越界 / C committer 越界 / D name 对 email 错 / E email 对 name 错 / F 空白名单。
- `.github/workflows/ci-identity.yml`：**刻意不加 paths 过滤**（身份与改了哪些文件无关），`fetch-depth: 0`（浅克隆会让区间解析失败，而失败方向是「查不到=放行」，最危险），且先跑反证再跑门禁——反证挂了就不该相信门禁的绿。

**本机（不入库）**

- `~/.git-allowed-identities`：本机白名单，3 个身份。
- `~/.git-templates/hooks/pre-commit`：新增白名单块；并修好上面那条空转了四个月的作者邮箱检查。
- `~/.git-templates/hooks/pre-push`：新增白名单块，逐条查要推的提交。
- 已部署到 6 个 personal 仓库，shasum 校验与模板一致。原文件备份在 `~/.git-hooks-backup-20260917/`。

**验收证据**

```
$ bash tools/test-commit-identity-gate.sh
  ✅ A 白名单身份必须绿（退出码 0，符合期望）
  ✅ B author 越界必须红（退出码 1，符合期望）
  ✅ C committer 越界必须红（退出码 1，符合期望）
  ✅ D name 对 email 错必须红（退出码 1，符合期望）
  ✅ E email 对 name 错必须红（退出码 1，符合期望）
  ✅ F 空白名单必须红（不得等于放行）（退出码 2，符合期望）
ok: 六个变异全部符合期望，门禁判据有效
```

对真实越界提交的反证（E2）——门禁逐条命中，author / committer 各报一次：

```
✗ 8005ec2b 的 author 不在白名单内：<越界身份>
✗ 8005ec2b 的 committer 不在白名单内：<越界身份>
✗ 7c68b487 的 author 不在白名单内：<越界身份>
...（6 个提交 × 2 个位置 = 12 条）
```

全史不误伤：

```
$ bash tools/check-commit-identity.sh <root>..HEAD
ok: 内 1065 个提交的 author/committer 全部在白名单内
```

**待你拍板：`dependabot[bot]` 留不留**

**2026-09-17 拍板：留。** 它是 GitHub 侧生成的固定机器人身份、不是人为可设置的，不构成安全风险；删掉的代价是 dependabot 的 PR 从此全部红灯、依赖升级要改人工做，不划算。与「历史里已把 dependabot 归并掉」的观感不一致是可接受的——历史清理针对的是身份泄漏，与未来是否允许机器人提交是两件事。

**留白**

- 门禁只管 author/committer 两个字段，**不管 `Co-Authored-By` 等 trailer**。trailer 是消息正文的一部分，按现有约定保留，不在本卡范围。
- 门禁拦不住 `--no-verify`（本机）——这是 git 的设计，本机 hook 按定义可绕过。服务端 lane 绕不过，这也正是它存在的理由。
