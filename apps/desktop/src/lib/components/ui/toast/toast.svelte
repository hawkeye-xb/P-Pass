<script lang="ts">
	let {
		message,
		onClose,
	}: {
		message: string;
		onClose: () => void;
	} = $props();
</script>

<p
	class="fixed top-6 left-1/2 z-[60] flex w-fit max-w-[min(90vw,360px)] -translate-x-1/2 items-center gap-[10px] rounded-md bg-ink px-[14px] py-[10px] text-[14px] leading-5 text-paper shadow-[0_4px_16px_rgba(23,21,18,0.18)]"
	role="status"
	aria-live="polite"
	aria-atomic="true"
>
	{message}
	<button
		class="flex-none rounded-[6px] px-[6px] py-[2px] text-[18px] leading-none text-paper/70 hover:bg-paper/15 hover:text-paper"
		aria-label="关闭提示"
		onclick={onClose}
	>
		×
	</button>
</p>
