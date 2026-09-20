-- DEV-03：设备离开列表的两种方式必须分得开。
--
-- 手机点「断开与这台电脑的连接」和业主在桌面点「移除设备」，此前都只是
-- `UPDATE device SET revoked = 1`——同一个布尔位，事后无从分辨。于是
-- 「家人与设备」只能一刀切按 `WHERE revoked = 0` 过滤，手机一断开设备就
-- 从列表里凭空消失，业主既看不到「它什么时候断的」，也无法确认「到底是
-- 哪一台」（设备可能被改过名）。
--
-- 两列都可空：历史行没有来源信息，读出来是 NULL，按「未知来源的吊销」
-- 处理（保守地当作业主移除，不凭空出现在列表里）。
ALTER TABLE device ADD COLUMN revoked_at INTEGER;

-- 'device' = 设备自己断开（手机侧点断开）
-- 'owner'  = 业主在桌面移除
ALTER TABLE device ADD COLUMN revoked_by TEXT;
