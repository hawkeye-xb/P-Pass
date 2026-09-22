import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  plugins: [svelte(), tailwindcss()],
  clearScreen: false,
  resolve: {
    alias: {
      // shadcn-svelte 组件用 $lib 别名引用 utils/components
      $lib: fileURLToPath(new URL("./src/lib", import.meta.url)),
    },
    // QA-16（#326）：vitest 下必须解析到 svelte 的 **browser** 入口。
    // 不加这条，`mount()` 落到 index-server.js 上，报
    // `lifecycle_function_unavailable: mount(...) is not available on
    // the server`——组件根本挂不起来。只在 VITEST 下打开，产品构建
    // 的解析条件一个字没动。
    conditions: process.env.VITEST ? ["browser"] : undefined,
  },
  server: {
    fs: { allow: ["../.."] }, // design tokens live at repo assets/design
    port: 1420,
    strictPort: true,
  },
});
