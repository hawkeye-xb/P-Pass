// DESK-09：后台服务启动失败时说给人听的那段话。
//
// 事故原貌（2026-08-25 真机）：daemon 因为版本降级打不开索引库，在自己的
// stderr 上重复了 8 次
//   Error: migration: migration 2 was previously applied but is missing in the resolved migrations
// 而界面只说「后台服务没有在 10 秒内就绪」。用户拿着这句话去查 dmg 布局、
// 只读卷、Gatekeeper、TCC，全是弯路。
//
// 三条规则：
// 1. **超时不是原因**，它只是"我们等不下去了"——文案不许把它当结论。
// 2. **原文照登**：daemon 报的那一行原样显示，不翻译、不截断（原文可搜索、
//    可贴给开发者）。
// 3. 已知的几类失败额外给一句人话 + 一个动作；不认识的就只给原文——
//    宁可少一句猜测，也不能拿假解释盖住真错误。

/** 已知失败类型 → 一句人话 + 一个动作。不认识返回 null。 */
export function daemonErrorHint(line) {
  if (!line) return null;
  // 版本装反：旧 daemon 打不开被新版迁移过的索引库。
  if (
    /missing in the resolved migrations/.test(line) ||
    /migration \d+ was previously applied/.test(line)
  ) {
    return "这个版本比你的照片库旧——旧版后台服务打不开新版整理过的照片索引。请装回新版本（测试版要从对应 tag 页下载，Releases 顶部给的是正式版）。";
  }
  // 端口被占：daemon 自己已经有人话错误（DAE-03），原样透出即可，不覆盖。
  if (/already in use|EADDRINUSE|端口/i.test(line)) return null;
  // 库目录不可写。
  if (
    /Read-only file system|Permission denied|Operation not permitted|not writable/i.test(
      line,
    )
  ) {
    return "照片库所在的文件夹不可写。回到第 1 步，选一个你有写权限的文件夹（别选只读磁盘或系统保护目录）。";
  }
  return null;
}

/**
 * 组装界面上那段话。
 * @param {{captured?: boolean, line?: string|null, errPath?: string|null, waitedSeconds?: number}} diag
 */
export function startupFailureMessage(diag = {}) {
  const { captured = false, line = null, errPath = null, waitedSeconds = 10 } = diag;
  const parts = [
    `后台服务没能起来（我们等了 ${waitedSeconds} 秒就不等了——超时只是我们等不下去了，不是失败的原因）。`,
  ];
  if (captured && line) {
    const hint = daemonErrorHint(line);
    if (hint) parts.push(hint);
    parts.push(`后台服务自己报的错误：${line}`);
  } else {
    parts.push(
      "这次没有捕获到后台服务的新错误输出。到「设置 → 导出日志」把诊断包（含后台服务日志与版本号）发给开发者。",
    );
  }
  if (errPath) parts.push(`完整日志：${errPath}`);
  return parts.join("\n");
}
