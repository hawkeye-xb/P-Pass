<script lang="ts" module>
	/* DESK-15：P-Pass Card 合同——shadcn 原装默认值（shadow-xs/ring-1/
	   --card-spacing 24px 纵向内边距、无横向内边距）在这个 app 里从未被
	   直接用过：App.svelte 里每一处 <Card> 调用都手动覆盖成同一套
	   shell（rounded-xl border shadow-none ring-0 ring-transparent），
	   还各自再补一遍横向内边距（原组件压根没提供）。数值原样收编自这些
	   已经存在、反复出现的 override，不是重新设计。

	   size="flush"：给需要自己内部滚动、不要外层内边距的列表卡
	   （照片墙/家人与设备/活动记录）用；variant="danger" 给需要红色
	   警示背景的卡（设置页「停止后台服务」）用。 --card-spacing 仍保留
	   供 CardHeader/CardContent/CardFooter 消费（本 app 目前未使用这几个
	   子件，但保留它们的横向内边距契约不破坏）。 */
	export type CardSize = "default" | "flush";
	export type CardVariant = "default" | "danger";

	export function cardVariants({
		size = "default",
		variant = "default",
	}: { size?: CardSize; variant?: CardVariant } = {}) {
		return [
			"group/card flex flex-col gap-0 overflow-hidden rounded-xl border text-sm text-card-foreground shadow-none ring-0 ring-transparent [--card-spacing:--spacing(6)] has-[>img:first-child]:pt-0 data-[size=sm]:[--card-spacing:--spacing(4)] *:[img:first-child]:rounded-t-xl *:[img:last-child]:rounded-b-xl",
			size === "flush" ? "p-0" : "px-[22px] py-5",
			variant === "danger" ? "border-act bg-act-bg" : "border-border bg-card",
		].join(" ");
	}
</script>

<script lang="ts">
	import { cn, type WithElementRef } from "$lib/utils.js";
	import type { HTMLAttributes } from "svelte/elements";

	let {
		ref = $bindable(null),
		class: className,
		children,
		size = "default",
		variant = "default",
		...restProps
	}: WithElementRef<HTMLAttributes<HTMLDivElement>> & {
		size?: CardSize;
		variant?: CardVariant;
	} = $props();
</script>

<div
	bind:this={ref}
	data-slot="card"
	data-size={size}
	data-variant={variant}
	class={cn(cardVariants({ size, variant }), className)}
	{...restProps}
>
	{@render children?.()}
</div>
