<script lang="ts">
	import { cn } from "$lib/utils.js";
	import type { Snippet } from "svelte";
	import XIcon from "@lucide/svelte/icons/x";

	/* DESK-15：弹窗外壳收进组件——原 App.svelte 手写 .modal-backdrop/.modal
	   三处各自复制一份，现在只有一处视觉定义。行为：传了 onClose 就可以关——
	   点遮罩、按 Esc；再传 closeLabel 会在右上角放一个关闭按钮。不传 onClose
	   就没有任何关闭入口。面板内容点击不冒泡到遮罩。

	   待确认加入列表现在也传 onClose：关掉只是收起弹窗、不等于拒绝，请求
	   留在首页「待处理」里可以再打开（之前不给出口，内容一出问题整窗就卡死）。 */
	let {
		open,
		onClose = undefined,
		closeLabel = undefined,
		class: className,
		children,
	}: {
		open: boolean;
		onClose?: () => void;
		/** 右上角关闭按钮的无障碍名；不传就不放按钮（仍可点遮罩 / Esc 关）。 */
		closeLabel?: string;
		class?: string;
		children?: Snippet;
	} = $props();

	function onKeydown(e: KeyboardEvent) {
		if (open && onClose && e.key === "Escape") {
			e.preventDefault();
			onClose();
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

{#if open}
	<div
		class="fixed inset-0 z-50 flex items-center justify-center bg-ink/45"
		onclick={onClose}
	>
		<div
			role="dialog"
			aria-modal="true"
			class={cn(
				"relative w-[420px] max-w-[92vw] rounded-xl bg-paper px-[30px] pt-[26px] pb-[22px] text-center shadow-[0_18px_50px_rgba(0,0,0,0.28)]",
				className,
			)}
			onclick={(e) => e.stopPropagation()}
		>
			{#if onClose && closeLabel}
				<button
					type="button"
					data-slot="dialog-close"
					aria-label={closeLabel}
					class="absolute top-3 right-3 inline-flex size-8 items-center justify-center rounded-md text-ink-40 transition-colors outline-none hover:bg-linen hover:text-ink focus-visible:ring-3 focus-visible:ring-ring/50"
					onclick={onClose}
				>
					<XIcon class="size-4" aria-hidden="true" />
				</button>
			{/if}
			{@render children?.()}
		</div>
	</div>
{/if}
