# NAME-01 设备改名　级别 L0　【队尾，可砍】

decisions ②：ID 与显示名分离。daemon 加 `device.rename`（IPC，owner
本机操作；audit 记 device.renamed 旧名→新名+node_id）；桌面设备行改名
入口（点名字编辑）。审计/水位/一切逻辑仍按 node_id，显示层才用名字。

验收：改名后 devices.list 新名、audit 有记录、重启不丢；集成测试 +
反证（audit 断言删掉必红）。收尾照旧。
