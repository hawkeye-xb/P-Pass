<script>
  // DESK-03: 照片墙缩略图单元——进入视口才拉 thumb（按需加载，500 张
  // 不卡的标准姿势），拉完缓存 DOM（离开视口不销毁）。失败显示中性
  // 灰块，不打断墙的流。
  // DESK-34 (#428): daemon 回占位图时不当终态——窗口到期且可见时重取
  // 一次（编排见 thumbLoader.js）。
  // #551: `serviceEpoch` 由 App 在服务恢复（onServiceBackOnline）时递增；
  // 变了就让失败态的格子在可见时重取一次（非失败态 no-op，DOM 不重建）。
  import { untrack } from "svelte";
  import { invoke } from "@tauri-apps/api/core";
  import { createThumbLoader } from "./thumbLoader.js";

  let { hash, size = 256, serviceEpoch = 0 } = $props();
  let src = $state(null);
  let failed = $state(false);
  let el = $state(null);
  let started = false;

  // 组件（的当前根元素）可见时调 fn 一次。
  function whenVisible(fn) {
    if (!el) return () => {};
    const io = new IntersectionObserver((entries) => {
      if (!entries[0].isIntersecting) return;
      io.disconnect();
      fn();
    });
    io.observe(el);
    return () => io.disconnect();
  }

  const loader = createThumbLoader(
    {
      call: (method, params) => invoke("daemon_call", { method, params }),
      schedule: (ms, fn) => {
        const t = setTimeout(fn, ms);
        return () => clearTimeout(t);
      },
      whenVisible: (fn) => whenVisible(fn),
      onSrc: (s) => (src = s),
      onFailed: () => (failed = true),
    },
    {
      get hash() {
        return hash;
      },
      get size() {
        return size;
      },
    }
  );

  $effect(() => () => loader.dispose());

  // 首次运行时 loader 还没失败过，retryFailed 是 no-op；之后每次 epoch 变化触发。
  // 只跟踪 serviceEpoch：retryFailed 内部读 el，不许 el 变化（失败 → 绑灰块）
  // 也把重取触发一遍，否则离线时会自己重试。
  $effect(() => {
    serviceEpoch;
    untrack(() => loader.retryFailed());
  });

  $effect(() => {
    if (!el || started) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries[0].isIntersecting) return;
        io.disconnect();
        started = true;
        loader.load();
      },
      { rootMargin: "200px" }
    );
    io.observe(el);
    return () => io.disconnect();
  });
</script>

{#if src}
  <img class="thumb" src={src} alt="" loading="lazy" bind:this={el} />
{:else if failed}
  <!-- #551: 失败格子也要绑 el，服务恢复后的重取靠它判可见。 -->
  <div class="thumb thumb-fail" bind:this={el}></div>
{:else}
  <div class="thumb thumb-skeleton" bind:this={el}></div>
{/if}

<style>
  .thumb {
    width: 100%;
    height: 100%;
    object-fit: cover;
    display: block;
    border-radius: var(--pp-radius-control-sm, 6px);
    background: var(--pp-border, #e8e0d5);
  }
  .thumb-fail {
    background: var(--pp-border, #e8e0d5);
  }
  .thumb-skeleton {
    background: var(--pp-border, #e8e0d5);
  }
</style>
