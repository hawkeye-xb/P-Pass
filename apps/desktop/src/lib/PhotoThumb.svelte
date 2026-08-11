<script>
  // DESK-03: 照片墙缩略图单元——进入视口才拉 thumb（按需加载，500 张
  // 不卡的标准姿势），拉完缓存 DOM（离开视口不销毁）。失败显示中性
  // 灰块，不打断墙的流。
  import { invoke } from "@tauri-apps/api/core";

  let { hash, size = 256 } = $props();
  let src = $state(null);
  let failed = $state(false);
  let el = $state(null);

  $effect(() => {
    if (!el || src || failed) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (!entries[0].isIntersecting) return;
        io.disconnect();
        load();
      },
      { rootMargin: "200px" }
    );
    io.observe(el);
    return () => io.disconnect();
  });

  async function load() {
    try {
      const r = await invoke("daemon_call", {
        method: "thumb.get",
        params: { hash, size },
      });
      src = `data:image/jpeg;base64,${r.jpeg_base64}`;
    } catch (_) {
      failed = true;
    }
  }
</script>

{#if src}
  <img class="thumb" src={src} alt="" loading="lazy" />
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
