// T-092 验收脚本：node 直跑 formatBytes / diskUsedPercent / connectionText /
// connectionDot 边界断言。用法：node apps/desktop/scripts/check-wire-fns.mjs
import { formatBytes, diskUsedPercent } from "../src/lib/formatBytes.js";
import { connectionText, connectionDot, presenceText } from "../src/lib/connection.js";

let failed = 0;
function eq(label, actual, expected) {
  const ok = actual === expected;
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
}

const GB = 1024 ** 3;

// ---- formatBytes（卡点名用例：0 / 1023B / 1.5GB / 500GB / null→null） ----
eq("0 -> 0 B", formatBytes(0), "0 B");
eq("1023 -> 1023 B（1024 进制，不跳档）", formatBytes(1023), "1023 B");
eq("1024 -> 1 KB", formatBytes(1024), "1 KB");
eq("1.5 GB -> 1.5 GB（<10 保留 1 位小数）", formatBytes(1.5 * GB), "1.5 GB");
eq("500 GB -> 500 GB（>=10 取整）", formatBytes(500 * GB), "500 GB");
eq("182 GB -> 182 GB（设计稿量级）", formatBytes(182 * GB), "182 GB");
eq("2048 GB -> 2 TB（进 TB 档）", formatBytes(2048 * GB), "2 TB");
eq("null -> null（整行隐藏）", formatBytes(null), null);
eq("undefined -> null", formatBytes(undefined), null);
eq("负值 -> null", formatBytes(-1), null);
eq("NaN -> null", formatBytes(NaN), null);

// ---- diskUsedPercent（进度条宽度） ----
eq("free=182GB total=494GB -> 63%（设计稿数字）", diskUsedPercent(182 * GB, 494 * GB), 63);
eq("free=total -> 0%", diskUsedPercent(494 * GB, 494 * GB), 0);
eq("free=0 -> 100%", diskUsedPercent(0, 494 * GB), 100);
eq("total=0 -> null（不除零）", diskUsedPercent(0, 0), null);
eq("free=null -> null", diskUsedPercent(null, 494 * GB), null);
eq("total=null -> null", diskUsedPercent(182 * GB, null), null);

// ---- connectionText 四态映射（设计稿/卡原文话术逐字） ----
eq("direct -> 已直连", connectionText("direct"), "已直连");
eq(
  "relay -> 中继话术（原文逐字）",
  connectionText("relay"),
  "经中继连接——内容加密，中继无法读取"
);
eq(
  "offline + 最后在线 -> 离线，最后在线 <时间>",
  connectionText("offline", "昨天 22:40"),
  "离线，最后在线 昨天 22:40"
);
eq("offline 无最后在线时间 -> 只说离线", connectionText("offline", null), "离线");
eq("unknown -> null（调用方保持 T-082 中性占位）", connectionText("unknown"), null);
eq("缺失字段(undefined) -> null", connectionText(undefined), null);

// ---- connectionDot 点色（direct=safe 绿 / relay=wait 琥珀 / 其余 idle） ----
eq("direct -> safe", connectionDot("direct"), "safe");
eq("relay -> wait", connectionDot("relay"), "wait");
eq("offline -> idle", connectionDot("offline"), "idle");
eq("unknown -> idle", connectionDot("unknown"), "idle");
eq("缺失字段(undefined) -> idle", connectionDot(undefined), "idle");

// ---- PRES-01 presenceText 三档 → sub/dot（online 优先连接路径事实） ----
const eqObj = (label, actual, expected) => {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${label}: got ${JSON.stringify(actual)}, want ${JSON.stringify(expected)}`);
};
eqObj("online+direct -> 已直连/safe", presenceText("online", "direct"), { sub: "已直连", dot: "safe" });
eqObj(
  "online+relay -> 中继话术/wait",
  presenceText("online", "relay"),
  { sub: "经中继连接——内容加密，中继无法读取", dot: "wait" }
);
eqObj("online 心跳新鲜无活连接 -> 在线/safe", presenceText("online", "unknown"), { sub: "在线", dot: "safe" });
eqObj("recent -> 3 分钟前在线/idle", presenceText("recent", "unknown", "3 分钟前"), { sub: "3 分钟前在线", dot: "idle" });
eqObj("recent 无相对时间 -> 刚刚在线", presenceText("recent", "unknown", null), { sub: "刚刚在线", dot: "idle" });
eqObj(
  "offline + 最后在线 -> 离线，最后在线 <时间>",
  presenceText("offline", "offline", null, "昨天 22:40"),
  { sub: "离线，最后在线 昨天 22:40", dot: "idle" }
);
eqObj("offline 无 last_seen -> 等待下次备份上报", presenceText("offline", "unknown", null, null), {
  sub: "等待下次备份上报",
  dot: "idle",
});

if (failed > 0) {
  console.error(`\n${failed} assertion(s) FAILED`);
  process.exit(1);
}
console.log("\nall assertions passed");