-- DEV-03 回填：历史吊销行的来源，审计流里是有答案的。
--
-- 单独一版而不是并进 0008：0008 可能已经在用户库上跑过（本机就是），
-- 回头改它会让 sqlx 校验和不匹配、daemon 直接起不来。
--
-- 不回填的话，升级前就已断开的设备要等到「下次重连」或「下次再断一遍」
-- 才会正确出现在列表里——而这恰恰是本卡要修的那个症状，等于让用户再
-- 忍受一轮。实测本机那台 SM-S9210 升级后就正好落在这个处境里。
--
-- `device.unpaired` 的 actor 是**设备自己**（router.handle_unpair 记的是
-- peer），`device.revoked` 的 actor 是 NULL（业主经本机 IPC 操作）。所以
-- 只认前者，按 node_id 取该设备最近一次的那条。
--
-- 判据与 `Db::backfill_revocation_provenance` 同一份（那边可被单测直接
-- 调用——迁移只跑一次，没法在测试里重放）。
UPDATE device
SET revoked_by = 'device',
    revoked_at = (
      SELECT MAX(occurred_at) FROM audit_operation
      WHERE kind = 'device.unpaired' AND actor = device.node_id
    )
WHERE revoked = 1
  AND revoked_by IS NULL
  AND EXISTS (
    SELECT 1 FROM audit_operation
    WHERE kind = 'device.unpaired' AND actor = device.node_id
  );

-- 剩下的（revoked = 1 但审计里查不到自我断开记录）保持 NULL，展示层按
-- 「业主移除」处理——保守方向：宁可让一台老设备不出现在列表里，也不要
-- 凭空冒出一台业主早就移除掉的。
