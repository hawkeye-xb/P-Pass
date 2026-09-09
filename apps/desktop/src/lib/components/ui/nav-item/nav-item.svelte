<script lang="ts">
	import { cn } from "$lib/utils.js";
	import type { Component } from "svelte";

	/* DESK-15：侧栏导航项收进组件——原 App.svelte .nav-item/.nav-icon/
	   .nav-label 三条规则（含 <1080px 收起成纯图标的响应式覆盖）原样
	   收编为 Tailwind class，数值不变，不是重新设计。图标颜色靠
	   currentColor 跟随按钮文字色，不用像原 CSS 那样单独覆盖。 */
	let {
		icon: Icon,
		label,
		active = false,
		onclick,
		class: className,
	}: {
		icon: Component<{ class?: string; size?: number }>;
		label: string;
		active?: boolean;
		onclick?: () => void;
		class?: string;
	} = $props();
</script>

<button
	class={cn(
		"flex w-full items-center gap-2 rounded-sm px-3 py-2.5 text-left text-[15px] font-medium text-ink-60 hover:bg-hairline data-[active=true]:bg-ink data-[active=true]:font-bold data-[active=true]:text-paper max-[1079px]:h-11 max-[1079px]:w-11 max-[1079px]:flex-none max-[1079px]:justify-center max-[1079px]:p-0",
		className,
	)}
	data-active={active}
	aria-current={active ? "page" : undefined}
	title={label}
	{onclick}
>
	<Icon class="hidden max-[1079px]:block" size={20} />
	<span class="max-[1079px]:hidden">{label}</span>
</button>
