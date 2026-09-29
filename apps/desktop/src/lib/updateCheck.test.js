import { describe, expect, it } from "vitest";
import { testManifestOutcome } from "./updateCheck.js";

describe("REL-07 test 通道 manifest 响应分类", () => {
  it("2xx → ok", () => {
    expect(testManifestOutcome(200)).toBe("ok");
  });

  it("404 → none（没有 test release = 无更新）", () => {
    expect(testManifestOutcome(404)).toBe("none");
  });

  it("5xx / 403 / 429 → failed（上游故障不是「已是最新」）", () => {
    for (const s of [500, 502, 503, 403, 429]) expect(testManifestOutcome(s)).toBe("failed");
  });
});
