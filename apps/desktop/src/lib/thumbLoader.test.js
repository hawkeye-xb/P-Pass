// DESK-34 (#428): 占位图有界重取的回归锁。
import { describe, expect, it } from "vitest";
import { createThumbLoader } from "./thumbLoader.js";

const REAL = { jpeg_base64: "REAL" };
const placeholder = (ms) => ({ jpeg_base64: "GRAY", placeholder: true, retry_after_ms: ms });

/** 手动推进的假计时器 + 假可见性；call 按脚本依次返回。 */
function harness(replies, { visible = true } = {}) {
  const calls = [];
  const timers = [];
  const visWaiters = [];
  const state = { src: null, failed: false, visible };
  const deps = {
    call: async (method, params) => {
      calls.push({ method, params });
      const r = replies[Math.min(calls.length - 1, replies.length - 1)];
      if (r instanceof Error) throw r;
      return r;
    },
    schedule: (ms, fn) => {
      const t = { ms, fn, cancelled: false };
      timers.push(t);
      return () => (t.cancelled = true);
    },
    whenVisible: (fn) => {
      const w = { fn, cancelled: false };
      if (state.visible) fn();
      else visWaiters.push(w);
      return () => (w.cancelled = true);
    },
    onSrc: (s) => (state.src = s),
    onFailed: () => (state.failed = true),
  };
  const loader = createThumbLoader(deps, { hash: "abc", size: 256 });
  const flush = () => new Promise((r) => setTimeout(r, 0));
  const fire = async () => {
    const pending = timers.filter((t) => !t.cancelled && !t.fired);
    for (const t of pending) {
      t.fired = true;
      t.fn();
    }
    await flush();
  };
  const becomeVisible = async () => {
    state.visible = true;
    for (const w of visWaiters.splice(0)) if (!w.cancelled) w.fn();
    await flush();
  };
  return { loader, calls, timers, state, flush, fire, becomeVisible };
}

describe("真图是终态", () => {
  it("真图不排任何重取", async () => {
    const h = harness([REAL]);
    await h.loader.load();
    expect(h.state.src).toBe("data:image/jpeg;base64,REAL");
    expect(h.timers).toHaveLength(0);
    expect(h.calls).toHaveLength(1);
  });
});

describe("占位图有界重取", () => {
  it("按 daemon 给的 retry_after_ms 排一次，到期可见即重取，拿到真图", async () => {
    const h = harness([placeholder(600000), REAL]);
    await h.loader.load();
    expect(h.state.src).toBe("data:image/jpeg;base64,GRAY");
    expect(h.timers.map((t) => t.ms)).toEqual([600000]);
    expect(h.calls).toHaveLength(1); // 到期前不重取
    await h.fire();
    expect(h.calls).toHaveLength(2);
    expect(h.calls[1]).toEqual({ method: "thumb.get", params: { hash: "abc", size: 256 } });
    expect(h.state.src).toBe("data:image/jpeg;base64,REAL");
  });

  it("重取回来仍是占位图就停，不排第二次", async () => {
    const h = harness([placeholder(5000), placeholder(5000)]);
    await h.loader.load();
    await h.fire();
    expect(h.calls).toHaveLength(2);
    expect(h.timers).toHaveLength(1);
    await h.fire();
    expect(h.calls).toHaveLength(2);
    expect(h.state.src).toBe("data:image/jpeg;base64,GRAY");
  });

  it("到期时不可见就等可见，不可见期间不发请求", async () => {
    const h = harness([placeholder(5000), REAL], { visible: false });
    await h.loader.load();
    await h.fire();
    expect(h.calls).toHaveLength(1);
    await h.becomeVisible();
    expect(h.calls).toHaveLength(2);
    expect(h.state.src).toBe("data:image/jpeg;base64,REAL");
  });

  it("retry_after_ms 缺省/为 0（未知资产、旧 daemon）不重取", async () => {
    for (const r of [placeholder(0), { jpeg_base64: "GRAY", placeholder: true }]) {
      const h = harness([r]);
      await h.loader.load();
      expect(h.timers).toHaveLength(0);
    }
  });

  it("卸载后取消挂起的重取", async () => {
    const h = harness([placeholder(5000), REAL]);
    await h.loader.load();
    h.loader.dispose();
    expect(h.timers[0].cancelled).toBe(true);
    h.timers[0].fn(); // 即使计时器仍被触发也不重取
    await h.flush();
    expect(h.calls).toHaveLength(1);
  });

  it("调用报错显示失败灰块，不重取", async () => {
    const h = harness([new Error("daemon down")]);
    await h.loader.load();
    expect(h.state.failed).toBe(true);
    expect(h.timers).toHaveLength(0);
  });
});
