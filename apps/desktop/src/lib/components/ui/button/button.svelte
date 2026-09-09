<script lang="ts" module>
	import { type VariantProps, tv } from "tailwind-variants";
	import { cn, type WithElementRef } from "$lib/utils.js";
	import type { HTMLAnchorAttributes, HTMLButtonAttributes } from "svelte/elements";

	/* DESK-15：P-Pass 按钮合同——语义直接固化进组件，不再靠页面拼 class。
	   四个 variant 各自完整自洽（含高度/圆角/内边距/字号/颜色），调用方
	   不需要再传视觉 override class。数值来自 DESK-08 已像素验收过的
	   BTN/BTN_OUTLINE/BTN_DANGER/BTN_LINK 常量，原样收编，不是重新设计。

	   控件高度 44px = tokens.json size.desktop.tap-min，达标。按钮/链接
	   文字 15px/13.5px 低于 size.desktop.body-min(16px)——这是显式、
	   已文档化的例外：body-min 管的是段落正文，不含按钮标签这类界面
	   控件文字；15px 是 v3 设计稿与 DESK-08 像素验收过的实际值，不是
	   随手写小的漏网之鱼。 */
	export const buttonVariants = tv({
		base: "inline-flex shrink-0 items-center justify-center gap-1.5 whitespace-nowrap font-sans transition-colors outline-none select-none focus-visible:ring-3 focus-visible:ring-ring/50 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
		variants: {
			variant: {
				/* 主按钮：ink 底纸字，全站唯一强调色的行动点。高度/圆角/
				   内边距已含默认值，tap-min=44px（tokens.json）达标。 */
				primary: "h-11 min-h-11 rounded-md border border-ink bg-primary text-primary-foreground px-[18px] text-[15px] font-bold hover:bg-ink-hover",
				/* 次按钮：透明底 + 描边，中性次级动作 */
				secondary: "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-transparent px-[18px] text-[15px] font-semibold text-ink-60 hover:bg-linen hover:text-ink-60",
				/* 危险按钮：纸底红字红边，破坏性动作（远端设备/停止服务） */
				danger: "h-11 min-h-11 rounded-md border-[1.5px] border-border-strong bg-paper px-[18px] text-[15px] font-semibold text-act hover:border-act hover:bg-act-bg hover:text-act",
				/* 纯文字链接：不是按钮外观的次要跳转（"看全部""上一步"）；
				   本身就是紧凑例外，不吃 size=compact。 */
				link: "h-auto min-h-0 rounded-md border-none bg-transparent px-0 py-[2px] text-[13.5px] font-semibold text-ink-60 hover:bg-transparent hover:text-ink hover:underline hover:underline-offset-[3px]",
			},
			/* link 的安全绿变体："一切正常还有 N 台"这类正向次要跳转 */
			tone: {
				default: "",
				safe: "text-safe hover:text-safe",
			},
			size: {
				/* 默认不覆盖——高度已由 variant 给定 */
				default: "",
				/* 显式、已文档化的紧凑例外：仅用于卡片内联的次要操作行
				   （例如 Wizard 睡眠提示卡的「一键设置/去系统设置」），
				   不是新的默认值，只对 primary/secondary/danger 有意义。 */
				compact: "h-10 min-h-10 flex-none px-[18px] text-[14px]",
			},
		},
		defaultVariants: {
			variant: "primary",
			tone: "default",
			size: "default",
		},
	});

	export type ButtonVariant = VariantProps<typeof buttonVariants>["variant"];
	export type ButtonTone = VariantProps<typeof buttonVariants>["tone"];
	export type ButtonSize = VariantProps<typeof buttonVariants>["size"];

	export type ButtonProps = WithElementRef<HTMLButtonAttributes> &
		WithElementRef<HTMLAnchorAttributes> & {
			variant?: ButtonVariant;
			tone?: ButtonTone;
			size?: ButtonSize;
		};
</script>

<script lang="ts">
	let {
		class: className,
		variant = "primary",
		tone = "default",
		size = "default",
		ref = $bindable(null),
		href = undefined,
		type = "button",
		disabled,
		children,
		...restProps
	}: ButtonProps = $props();
</script>

{#if href}
	<a
		bind:this={ref}
		data-slot="button"
		class={cn(buttonVariants({ variant, tone, size }), className)}
		href={disabled ? undefined : href}
		aria-disabled={disabled}
		role={disabled ? "link" : undefined}
		tabindex={disabled ? -1 : undefined}
		{...restProps}
	>
		{@render children?.()}
	</a>
{:else}
	<button
		bind:this={ref}
		data-slot="button"
		class={cn(buttonVariants({ variant, tone, size }), className)}
		{type}
		{disabled}
		{...restProps}
	>
		{@render children?.()}
	</button>
{/if}
