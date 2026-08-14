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
  },
  server: {
    fs: { allow: ["../.."] }, // design tokens live at repo assets/design
    port: 1420,
    strictPort: true,
  },
});
