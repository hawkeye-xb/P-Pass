<script lang="ts" module>
	/* 同页所有 Dialog 实例共享的叠层状态（必须是 module script——写在实例
	   script 里就成了每个实例各一份，互相看不见）。 */
	// 当前开着的 Dialog 栈（打开序）：最上层 = 数组最后一个。
	const openDialogs: { panel: HTMLElement }[] = [];
	// 每个 Dialog 实例在自己打开期间标了 inert 的元素 → 标它的所有权凭据集合
	//（谁标谁摘：先关的不能把别的 Dialog 还需要的 inert 摘掉）。
	const inertOwners = new WeakMap<HTMLElement, Set<object>>();
</script>

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
	   Tab / Shift+Tab 在弹窗内循环、关闭后焦点回到打开前的元素；触发元素已不在 DOM
	   （「待确认加入」打开即移除触发按钮）、被禁用（禁用按钮收不到焦点）或打开时
	   本无焦点元素时，回主内容区 <main tabindex="-1"> 兜底，不落 body（#1132 验收 1）；
	   打开期间背景整树 inert（#1132 D1：HTML 标准 inert 让 Tab、点按与读屏都到
	   不了背景，是 APG「背景 inert」项的标准实现）——沿祖先链把不含弹窗的兄弟分支
	   全部标 inert，弹窗自身与其祖先不动。

	   多个弹窗同屏（大图查看器开着时来配对申请：查看器关、确认弹窗开落在同一轮
	   更新里，确认弹窗的 $effect 先跑、查看器的清理后跑——#1132 独立评审阻断），
	   inert 与焦点的所有权归「最上层那个」：
	   - inert 按引用计数：每个 Dialog 都登记自己要标 inert 的元素，关闭时只减
	     自己的计数，别的 Dialog 还在用的不摘；不是任何 Dialog 标的既有 inert
	     （如搬迁锁的 inert={relocLock}）照旧不碰。
	   - 焦点只在「自己关闭后没有别的 Dialog 还开着」时才恢复到触发元素；自己
	     之上还有 Dialog 时把焦点交还给最上层那个，后关的弹窗不抢走新弹窗的焦点，
	     也绝不把焦点落在 body。 */
	const FOCUSABLE =
		'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

	let panel: HTMLElement | undefined = $state();
	let backdrop: HTMLElement | undefined = $state();

	function focusables(): HTMLElement[] {
		return panel ? Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE)) : [];
	}

	$effect(() => {
		if (!open || !panel) return;
		const panelEl = panel;
		const opener =
			document.activeElement === document.body
				? null
				: (document.activeElement as HTMLElement | null);
		(focusables()[0] ?? panelEl).focus();
		const token = new Object();
		openDialogs.push({ panel: panelEl });
		const marked: HTMLElement[] = [];
		let node: HTMLElement | null = backdrop ?? panelEl;
		while (node && node !== document.body) {
			const parent = node.parentElement;
			if (!parent) break;
			for (const sib of parent.children) {
				if (sib !== node && !sib.contains(node)) {
					const owners = inertOwners.get(sib);
					if (sib.hasAttribute("inert") && !owners) continue; // 别处（如搬迁锁 inert={…}）先已置上的不碰
					sib.setAttribute("inert", "");
					if (owners) owners.add(token);
					else inertOwners.set(sib, new Set([token]));
					marked.push(sib as HTMLElement);
				}
			}
			node = parent;
		}
		return () => {
			const i = openDialogs.findIndex((d) => d.panel === panelEl);
			if (i >= 0) openDialogs.splice(i, 1);
			for (const el of marked) {
				const owners = inertOwners.get(el);
				if (!owners) continue;
				owners.delete(token);
				if (owners.size === 0) {
					inertOwners.delete(el);
					el.removeAttribute("inert");
				}
			}
			if (openDialogs.length > 0) {
				// 之上还有 Dialog：焦点归最上层那个，不抢（同一轮更新里先关查看器、
				// 再开确认弹窗时，它的 $effect 已把焦点带进弹窗）。
				const top = openDialogs[openDialogs.length - 1];
				if (!top.panel.contains(document.activeElement)) {
					(top.panel.querySelector<HTMLElement>(FOCUSABLE) ?? top.panel).focus();
				}
				return;
			}
			// 自己是最上层（没有别的 Dialog 接管）：焦点回触发元素；它已被移除、
			// 被禁用（focus 空转）或打开时本无焦点时，回 main 兜底，不落 body。
			if (opener && opener.isConnected) opener.focus();
			if (document.activeElement !== opener) document.querySelector("main")?.focus();
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
