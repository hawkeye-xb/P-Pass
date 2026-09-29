<script>
  // DESK-03: 照片墙缩略图单元——进入视口才拉 thumb（按需加载，500 张
  // 不卡的标准姿势），拉完缓存 DOM（离开视口不销毁）。失败显示中性
  // 灰块，不打断墙的流。
  // DESK-34 (#428): daemon 回占位图时不当终态——窗口到期且可见时重取
  // 一次（编排见 thumbLoader.js）。
  import { invoke } from "@tauri-apps/api/core";
  import { createThumbLoader } from "./thumbLoader.js";

  let { hash, size = 256 } = $props();
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
  <div class="thumb thumb-fail"></div>
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
