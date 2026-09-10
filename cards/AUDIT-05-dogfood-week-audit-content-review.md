# AUDIT-05 狗粮周后审计内容复核与投影决策（L2）

> ⬜ 状态：等待狗粮周真实数据后复核；此卡不编码
> 级别：L2 · 阻塞：需要一周正常使用产生的审计样本
> 前置：AUDIT-04 已归档，canonical audit 四表已落地

## 目的

AUDIT-04 已验证持久化与保留合同，但当前真实库仅覆盖少量 Flow 完成、对象证据和外部删除。它足以证明数据链正确，不足以决定用户应在活动页/详情里看见什么。

本卡在狗粮周后才开始：先审查真实审计内容，再决定 AUDIT-05 后续 UI 投影是否值得做、展示哪些内容和哪些内容必须保持诊断内部可见。

## 复核输入与问题

只读审查 `audit_operation`、`audit_item_evidence`、`audit_tombstone`、`audit_decision`：

1. 实际是否覆盖 Flow 完成、外部删除、取消/恢复/放弃恢复、范围/授权决定等业务事实；缺项应先追溯生产路径，不从 UI 猜。
2. operation / evidence / tombstone / decision 的关联是否能回答“发生了什么、涉及哪些对象、后来如何处理”。
3. actor 快照、当前名称与短指纹是否在人话可读和隐私最小化之间成立。
4. 是否存在连接、重试、路径、性能等诊断噪音混入长期表。
5. 哪些事实对用户有价值，哪些只适合日志/诊断；据此定 AUDIT-05 的活动页与详情投影，禁止复用被 AUDIT-04 取代的 `audit_event` 模型。

## 验收

- [ ] 狗粮周真实数据的四表只读汇总：数量、kind/outcome/reason/decision_kind 分布，以及 operation→evidence→tombstone/decision 关联覆盖。
- [ ] 每类真实业务 case 至少给出一条去标识化证据；未发生的 case 明确标为样本缺失，不补造数据。
- [ ] 明确列出应投影给用户、只留诊断、应修改生产路径三类内容，并写出理由。
- [ ] 形成 AUDIT-05 UI/详情投影的最小 case matrix 后，才允许新建实现卡。

## 不准动

- 不写审计 UI、schema、迁移或生产路由。
- 不为凑样本生成截图、直接写 SQLite 或改变真实照片/配对状态。
- 不把 AUDIT-01 的 `audit_event` 或旧 action/detail 语义重新带回实现。
