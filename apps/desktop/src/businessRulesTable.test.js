// #1049 E2：docs/desktop/business-rules.zh-CN.md §12 常量表里「归属 = desktop-ui」
// 的行 ↔ 前端导出的常量，双向比对（daemon 与壳 Rust 的行由各自的 cargo 测试校验）。
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { EXTERNAL_DELETE_WINDOW_MS } from "./lib/externalDelete.js";
import { FALLBACK_REFRESH_MS, SELF_HEAL_COOLDOWN_MS } from "./lib/serviceTiming.js";
import { READY_POLL_MS, READY_POLLS } from "./lib/wizardFlow.js";

const DOC = readFileSync(
  fileURLToPath(new URL("../../../docs/desktop/business-rules.zh-CN.md", import.meta.url)),
  "utf8",
);
const OWNER = "desktop-ui";

const REGISTRY = {
  "lib/serviceTiming.js::SELF_HEAL_COOLDOWN_MS": [SELF_HEAL_COOLDOWN_MS, "ms"],
  "lib/serviceTiming.js::FALLBACK_REFRESH_MS": [FALLBACK_REFRESH_MS, "ms"],
  "lib/externalDelete.js::EXTERNAL_DELETE_WINDOW_MS": [EXTERNAL_DELETE_WINDOW_MS, "ms"],
  "lib/wizardFlow.js::READY_POLLS": [READY_POLLS, "个"],
  "lib/wizardFlow.js::READY_POLL_MS": [READY_POLL_MS, "ms"],
};

/** `## 12` 节第一张表里本归属的行：符号 → [值, 单位]。 */
function parseTable(doc) {
  const start = doc.indexOf("\n## 12 ");
  if (start < 0) throw new Error("文档缺少 `## 12 数字常量总表`");
  let section = doc.slice(start + 1);
  const end = section.indexOf("\n## ", 3);
  if (end >= 0) section = section.slice(0, end);
  const rows = {};
  let inTable = false;
  for (const raw of section.split("\n")) {
    const line = raw.trim();
    if (!line.startsWith("|")) {
      if (inTable) break;
      continue;
    }
    const cells = line.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
    if (cells[0] === "符号" || cells.every((c) => /^-+$/.test(c))) {
      inTable = true;
      continue;
    }
    if (cells[1] !== OWNER) continue;
    rows[cells[0].replace(/`/g, "")] = [Number(cells[2]), cells[3]];
  }
  return rows;
}

function mismatches(doc) {
  const table = parseTable(doc);
  const out = [];
  for (const [symbol, want] of Object.entries(REGISTRY)) {
    const got = table[symbol];
    if (!got) out.push(`代码常量 ${symbol} 在 §12 没有 ${OWNER} 行`);
    else if (got[0] !== want[0] || got[1] !== want[1])
      out.push(`${symbol}：表里 ${got.join(" ")}，代码 ${want.join(" ")}`);
  }
  for (const symbol of Object.keys(table)) {
    if (!(symbol in REGISTRY)) out.push(`§12 行 ${symbol} 没有对应的代码登记`);
  }
  return out;
}

describe("§12 常量表（desktop-ui）", () => {
  it("与前端常量一致", () => {
    expect(mismatches(DOC)).toEqual([]);
  });

  it("反证：改一个值、删一行都会被抓到", () => {
    const changed = DOC.replace(
      "| `lib/serviceTiming.js::FALLBACK_REFRESH_MS` | desktop-ui | 60000 |",
      "| `lib/serviceTiming.js::FALLBACK_REFRESH_MS` | desktop-ui | 3000 |",
    );
    expect(changed).not.toBe(DOC);
    expect(mismatches(changed).some((m) => m.includes("FALLBACK_REFRESH_MS"))).toBe(true);

    const dropped = DOC.split("\n")
      .filter((l) => !l.includes("`lib/wizardFlow.js::READY_POLLS`"))
      .join("\n");
    expect(mismatches(dropped).some((m) => m.includes("READY_POLLS"))).toBe(true);
  });
});
