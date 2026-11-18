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
		ariaLabel = undefined,
		ariaLabelledby = undefined,
		class: className,
		children,
	}: {
		open: boolean;
		onClose?: () => void;
		/** 右上角关闭按钮的无障碍名；不传就不放按钮（仍可点遮罩 / Esc 关）。 */
		closeLabel?: string;
		/** 弹窗的无障碍名（aria-label）；给不了元素引用时用这个。 */
		ariaLabel?: string;
		/** 弹窗的无障碍名（aria-labelledby），指向面板内标题元素的 id。 */
		ariaLabelledby?: string;
		class?: string;
		children?: Snippet;
	} = $props();

	/* WAI-ARIA 模态对话框：打开时焦点进弹窗（第一个可聚焦元素，没有就聚焦面板本身）、
	   Tab / Shift+Tab 在弹窗内循环、关闭后焦点回到打开前的元素（已不在 DOM 就跳过）；
	   打开期间背景整树 inert（#1132 D1：HTML 标准 inert 让 Tab、点按与读屏都到
	   不了背景，是 APG「背景 inert」项的标准实现）——沿祖先链把不含弹窗的兄弟分支
	   全部标 inert，弹窗自身与其祖先不动；清理时只摘掉自己标的，别人（如
	   搬迁锁的 inert={…}）先已置上的不碰。 */
	const FOCUSABLE =
		'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

	let panel: HTMLElement | undefined = $state();
	let backdrop: HTMLElement | undefined = $state();

	function focusables(): HTMLElement[] {
		return panel ? Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)) : [];
	}

	$effect(() => {
		if (!open || !panel) return;
		const opener = document.activeElement as HTMLElement | null;
		(focusables()[0] ?? panel).focus();
		const marked: HTMLElement[] = [];
		let node: HTMLElement | null = backdrop ?? panel;
		while (node && node !== document.body) {
			const parent = node.parentElement;
			if (!parent) break;
			for (const sib of parent.children) {
				if (sib !== node && !sib.contains(node) && !sib.hasAttribute("inert")) {
					sib.setAttribute("inert", "");
					marked.push(sib as HTMLElement);
				}
			}
			node = parent;
		}
		return () => {
			for (const el of marked) el.removeAttribute("inert");
			if (opener && opener.isConnected) opener.focus();
		};
	});

	function onKeydown(e: KeyboardEvent) {
		if (!open) return;
		if (onClose && e.key === "Escape") {
			e.preventDefault();
			onClose();
			return;
		}
		if (e.key !== "Tab" || !panel) return;
		const items = focusables();
		if (items.length === 0) {
			e.preventDefault();
			panel.focus();
			return;
		}
		const first = items[0];
		const last = items[items.length - 1];
		const active = document.activeElement;
		const outside = !panel.contains(active) || active === panel;
		if (e.shiftKey && (active === first || outside)) {
			e.preventDefault();
			last.focus();
		} else if (!e.shiftKey && (active === last || outside)) {
			e.preventDefault();
			first.focus();
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

{#if open}
	<div
		bind:this={backdrop}
		class="fixed inset-0 z-50 flex items-center justify-center bg-ink/45"
		onclick={onClose}
	>
		<div
			bind:this={panel}
			role="dialog"
			aria-modal="true"
			aria-label={ariaLabel}
			aria-labelledby={ariaLabelledby}
			tabindex="-1"
			class={cn(
				"relative outline-none w-[420px] max-w-[92vw] rounded-xl bg-paper px-[30px] pt-[26px] pb-[22px] text-center shadow-[0_18px_50px_rgba(0,0,0,0.28)]",
				className,
			)}
			onclick={(e) => e.stopPropagation()}
		>
			{#if onClose && closeLabel}
				<button
					type="button"
					data-slot="dialog-close"
					aria-label={closeLabel}
					class="absolute top-3 right-3 inline-flex size-8 items-center justify-center rounded-md text-ink-40 transition-colors outline-none hover:bg-linen hover:text-ink focus-visible:ring-3 focus-visible:ring-ring"
					onclick={onClose}
				>
					<XIcon class="size-4" aria-hidden="true" />
				</button>
			{/if}
			{@render children?.()}
		</div>
	</div>
{/if}
