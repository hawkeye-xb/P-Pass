import "../../../assets/design/tokens.css";
import "./app.css";
import { mount } from "svelte";
import App from "./App.svelte";
import { setupTitlebarDragRegions } from "./titlebar.js";

const app = mount(App, { target: document.getElementById("app") });

// macOS Overlay 标题栏：给侧栏/向导头部打 data-tauri-drag-region
// （红绿灯悬浮后，这些区域就是窗口的"假标题栏"）。
setupTitlebarDragRegions();

export default app;
