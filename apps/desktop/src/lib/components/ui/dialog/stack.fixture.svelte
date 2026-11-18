<!-- dialog 叠层测试夹具（dialog.test.js 用）：两个 Dialog 由同一组 props 驱动，
     一轮 props 更新同时翻转 confirmOpen / viewerOpen——复现「大图查看器开着时
     来配对申请」（App.svelte 里 photoViewer = null 与 showConfirmModal = true
     落在同一批，#1132 独立评审阻断）。
     模板序照 App.svelte：确认弹窗在前（2444）、查看器在后（2510）。同一轮更新
     里「查看器关、确认弹窗开」时按创建序跑 effect：确认弹窗的 $effect 先跑
     （此时背景还带着查看器设的 inert），查看器的清理后跑——正是 bug 的触发顺序。 -->
<script lang="ts">
	import Dialog from "./dialog.svelte";
	import { createRawSnippet } from "svelte";

	let { confirmOpen = false, viewerOpen = false }: { confirmOpen?: boolean; viewerOpen?: boolean } = $props();
	const item = (id: string) =>
		createRawSnippet(() => ({ render: () => `<button id="${id}">item</button>` }));
</script>

<button id="trigger" type="button">open</button>
<Dialog open={confirmOpen} onClose={() => {}} children={item("in-confirm")} />
<Dialog open={viewerOpen} onClose={() => {}} children={item("in-viewer")} />
