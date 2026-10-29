// #1264：码还能不能扫，只拿 daemon 给的失效时刻比当前时刻。
// 反证：去掉 `autoRefreshes < max` ⇒「换满次数后盖住」红；去掉 isFinite 守卫 ⇒「老 daemon」红。
import { describe, expect, it } from "vitest";
import { QR_AUTO_REFRESH_MAX, QR_REFRESH_LEAD_MS, qrPhase } from "./pairQr.js";

const exp = 1_000_000;

describe("qrPhase", () => {
  it("离失效还远：照常显示", () => {
    expect(qrPhase({ now: exp - QR_REFRESH_LEAD_MS - 1, expiresAt: exp, autoRefreshes: 0 })).toBe("show");
  });
  it("进入提前量：自动换码（含已经过期、睡眠醒来的那一刻）", () => {
    expect(qrPhase({ now: exp - QR_REFRESH_LEAD_MS, expiresAt: exp, autoRefreshes: 0 })).toBe("refresh");
    expect(qrPhase({ now: exp + 3_600_000, expiresAt: exp, autoRefreshes: 0 })).toBe("refresh");
  });
  it("自动换满次数后：到期前照常显示，过期即盖住", () => {
    const n = QR_AUTO_REFRESH_MAX;
    expect(qrPhase({ now: exp - 1, expiresAt: exp, autoRefreshes: n })).toBe("show");
    expect(qrPhase({ now: exp, expiresAt: exp, autoRefreshes: n })).toBe("show");
    expect(qrPhase({ now: exp + 1, expiresAt: exp, autoRefreshes: n })).toBe("expired");
  });
  it("老 daemon 不给失效时刻：不换码、不盖码", () => {
    for (const expiresAt of [null, undefined, NaN]) {
      expect(qrPhase({ now: exp * 10, expiresAt, autoRefreshes: 0 })).toBe("show");
    }
  });
});
