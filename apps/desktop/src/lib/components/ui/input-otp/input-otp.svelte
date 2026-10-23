<script lang="ts">
	import { cn } from "$lib/utils.js";
	import type { HTMLInputAttributes } from "svelte/elements";

	/* 分格验证码输入（input-otp 的标准做法：一个真实 <input> 叠在 N 个格子上）。
	   不是 N 个 input 互相跳焦——那要自己处理粘贴拆分、退格回跳、输入法与
	   系统「一次性验证码」自动填充，每一条都容易漏。一个 input 时这些都是浏览器
	   原生行为：打字光标天然落到下一格，粘贴「123 456」一次进来，退格删掉最后
	   一位就回到上一格。格子只负责显示。

	   不引 bits-ui 的 PinInput：项目的 shadcn 组件都是本地手写、零运行时依赖，
	   为一个输入框带进整套无头组件库不值，且正式包开着 freezePrototype（#1120
	   刚因第三方库白屏过一次）。 */
	let {
		value = $bindable(""),
		length = 6,
		onEnter = undefined,
		class: className,
		...rest
	}: {
		value?: string;
		length?: number;
		/** 回车且已填满时调用。 */
		onEnter?: (value: string) => void;
		class?: string;
	} & Omit<HTMLInputAttributes, "value" | "class"> = $props();

	let focused = $state(false);
	const digitsOnly = (raw: string) => raw.replace(/[^0-9]/g, "").slice(0, length);
	const slots = $derived(Array.from({ length }, (_, i) => value[i] ?? ""));
	// 光标所在的格子：下一位要填的那格；填满后停在最后一格。
	const active = $derived(Math.min(value.length, length - 1));

	function onInput(e: Event & { currentTarget: HTMLInputElement }) {
		const next = digitsOnly(e.currentTarget.value);
		e.currentTarget.value = next;
		value = next;
	}

	// 光标永远在末尾：格子是按位置显示的，中间插入会让显示与实际错位。
	function caretToEnd(e: Event & { currentTarget: HTMLInputElement }) {
		const el = e.currentTarget;
		const end = el.value.length;
		if (el.selectionStart !== end || el.selectionEnd !== end) el.setSelectionRange(end, end);
	}
</script>

<div class={cn("relative inline-flex gap-1.5", className)} data-slot="input-otp">
	{#each slots as digit, i}
		<div
			data-slot="input-otp-slot"
			data-active={focused && i === active ? "" : undefined}
			class={cn(
				"flex h-11 w-9 items-center justify-center rounded-md border-[1.5px] border-border-strong bg-paper text-[18px] font-semibold text-ink tabular-nums transition-colors",
				focused && i === active && "border-ink ring-3 ring-ring/15",
			)}
		>
			{digit}
		</div>
	{/each}
	<input
		{...rest}
		class="absolute inset-0 h-full w-full cursor-text border-0 bg-transparent text-transparent caret-transparent opacity-0 outline-none"
		type="text"
		inputmode="numeric"
		autocomplete="one-time-code"
		pattern="[0-9]*"
		maxlength={length}
		{value}
		oninput={onInput}
		onfocus={(e) => {
			focused = true;
			caretToEnd(e);
		}}
		onblur={() => (focused = false)}
		onselect={caretToEnd}
		onkeydown={(e) => {
			if (e.key === "Enter" && value.length === length) onEnter?.(value);
		}}
	/>
</div>
