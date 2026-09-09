<script lang="ts">
	/* DESK-15：UX-08 提示条收进组件——原 App.svelte 两处（wizard-shell 头部 /
	   shell 内容区）各自复制一份完全相同的 .message/.message-close，现在
	   只有一处视觉定义。数值原样收编自原 CSS，不是重新设计。 */
	let {
		message,
		onClose,
	}: {
		message: string;
		onClose: () => void;
	} = $props();
</script>

<p
	class="fixed top-4 left-1/2 z-[60] flex max-w-[min(90vw,560px)] -translate-x-1/2 items-center justify-between gap-[10px] rounded-md border border-waiting bg-waiting-bg px-[14px] py-[10px] text-[15px] shadow-[0_4px_16px_rgba(23,21,18,0.12)]"
>
	{message}
	<!-- UX-08: 提示条右侧 × 手动关闭（5s 自动消失之外的第二条路） -->
	<button
		class="flex-none rounded-[6px] px-[6px] py-[2px] text-[18px] leading-none text-ink-40 hover:bg-linen hover:text-ink"
		aria-label="关闭提示"
		onclick={onClose}
	>
		×
	</button>
</p>
