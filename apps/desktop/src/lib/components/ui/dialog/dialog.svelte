<script lang="ts">
	import { cn } from "$lib/utils.js";
	import type { Snippet } from "svelte";

	/* DESK-15：弹窗外壳收进组件——原 App.svelte 手写 .modal-backdrop/.modal
	   三处各自复制一份，现在只有一处视觉定义。行为对齐原实现：传了 onClose
	   就点遮罩关闭（配对二维码/大图查看器）；不传就不关（待确认加入列表——
	   必须显式选允许/拒绝，不能背景一点就消失）。面板内容点击不冒泡到遮罩。 */
	let {
		open,
		onClose = undefined,
		class: className,
		children,
	}: {
		open: boolean;
		onClose?: () => void;
		class?: string;
		children?: Snippet;
	} = $props();
</script>

{#if open}
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-ink/45"
		onclick={onClose}
	>
		<div
			class={cn(
				"w-[420px] max-w-[92vw] rounded-xl bg-paper px-[30px] pt-[26px] pb-[22px] text-center shadow-[0_18px_50px_rgba(0,0,0,0.28)]",
				className,
			)}
			onclick={(e) => e.stopPropagation()}
		>
			{@render children?.()}
		</div>
	</div>
{/if}
