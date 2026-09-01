# REBUILD-00 旧备份线冻结与新 Flow 边界（L2）

> 🟠 状态：进行中 · 协同分支：`main`
> 级别：L2 · 阻塞：无

## 问题

旧 `BackupWorker → BackupRunner → manifest/push/commit` 仍是唯一生产路径；ARCH-01 的账本/消费者零件与旧代码混在同一包，后续 agent 无法可靠区分新旧入口，旧测试也会把新实现拉回批次机制。

## 期望行为

建立物理且可审查的边界：旧批次入口标为 `legacy`、禁止新增功能；新生产核心只进入 `backup/flow`。旧测试分类为产品不变量、legacy 机制、未知三类；legacy 机制测试冻结，不作为新 Flow 门禁。

## 验收标准

- [ ] 旧 Worker/Runner/ConfirmedStore/ReuploadQueue 与新 Flow 的职责清单落在代码边界说明中。
- [ ] 新 `backup/flow` 包成为新核心唯一落点；任何新 Flow 文件不得 import legacy batch API。
- [ ] 旧批次实现仍可编译，但新主线卡不再修改它。
- [ ] 旧测试按三类列清，不删全仓无关测试。
- [ ] `just ci` 通过。

## 范围

- 只准动：Android backup 包的边界/标记、测试分类清单、任务队列的 legacy 分区。
- 不准动：旧管线业务行为、UI、传输、配对、MediaStore 语义。

## 阻塞与依赖

无。完成后释放 REBUILD-01 / REBUILD-02 的并行开发。
