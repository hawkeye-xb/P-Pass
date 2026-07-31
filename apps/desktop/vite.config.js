import { defineConfig } from "vite";
import { svelte } from "@sveltejs/vite-plugin-svelte";

export default defineConfig({
  plugins: [svelte()],
  clearScreen: false,
  server: {
    fs: { allow: ["../.."] }, // design tokens live at repo assets/design
    port: 1420,
    strictPort: true,
  },
});
