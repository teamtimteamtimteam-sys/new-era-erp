import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { Slot } from "radix-ui"

import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "group/button inline-flex shrink-0 items-center justify-center rounded-lg border border-transparent bg-clip-padding text-sm font-medium whitespace-nowrap transition-all outline-none select-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 active:not-aria-[haspopup]:translate-y-px disabled:pointer-events-none disabled:opacity-50 aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground hover:bg-primary/80",
        outline:
          "border-border bg-background hover:bg-muted hover:text-foreground aria-expanded:bg-muted aria-expanded:text-foreground dark:border-input dark:bg-input/30 dark:hover:bg-input/50",
        secondary:
          "bg-secondary text-secondary-foreground hover:bg-[color-mix(in_oklch,var(--secondary),var(--foreground)_5%)] aria-expanded:bg-secondary aria-expanded:text-secondary-foreground",
        ghost:
          "hover:bg-muted hover:text-foreground aria-expanded:bg-muted aria-expanded:text-foreground dark:hover:bg-muted/50",
        destructive:
          "bg-destructive/10 text-destructive hover:bg-destructive/20 focus-visible:border-destructive/40 focus-visible:ring-destructive/20 dark:bg-destructive/20 dark:hover:bg-destructive/30 dark:focus-visible:ring-destructive/40",
        link: "text-primary underline-offset-4 hover:underline",
      },
      size: {
        default:
          "h-8 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        xs: "h-6 gap-1 rounded-[min(var(--radius-md),10px)] px-2 text-xs in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3",
        sm: "h-7 gap-1 rounded-[min(var(--radius-md),12px)] px-2.5 text-[0.8rem] in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3.5",
        lg: "h-9 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        icon: "size-8",
        "icon-xs":
          "size-6 rounded-[min(var(--radius-md),10px)] in-data-[slot=button-group]:rounded-lg [&_svg:not([class*='size-'])]:size-3",
        "icon-sm":
          "size-7 rounded-[min(var(--radius-md),12px)] in-data-[slot=button-group]:rounded-lg",
        "icon-lg": "size-9",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  }
)

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· `pending` —— 按下去之后【它还在跑】要看得见
// ════════════════════════════════════════════════════════════════════════════
// R1:【按下去是什么反应,是按钮自己的性质】,不是事后洒上去的东西。
// 所以这个状态属于按钮,而不是每一页各自在旁边摆一个"处理中…"。
//
// 【这个状态为什么值得反馈 —— 有一条真实的缺陷记录】
// IA-BUILD-1-fu1 的标题原文是「dock 的移除按下去五秒没反应」。
// 一个按下去没有任何回应的按钮,人会【再按一次】—— 而第二次点击是一次真的重复提交。
// 所以 pending 同时做三件事:转圈(看得见)、disabled(按不动)、aria-busy(读得出)。
//
// 【转圈只是动效,不是状态本身】减弱动效之下它停住不转,但按钮仍然是禁用的、
// aria-busy 仍然是 true —— 关掉的是动,不是这句话。
function Button({
  className,
  variant = "default",
  size = "default",
  asChild = false,
  pending = false,
  children,
  ...props
}: React.ComponentProps<"button"> &
  VariantProps<typeof buttonVariants> & {
    asChild?: boolean
    /** 提交中:转圈 + 禁用 + aria-busy。asChild 时忽略(那时渲染的不是 button)。 */
    pending?: boolean
  }) {
  const Comp = asChild ? Slot.Root : "button"
  const busy = pending && !asChild

  return (
    <Comp
      data-slot="button"
      data-variant={variant}
      data-size={size}
      aria-busy={busy || undefined}
      disabled={busy ? true : (props as React.ComponentProps<"button">).disabled}
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    >
      {busy && (
        <span
          aria-hidden
          className="base-spin inline-block size-3.5 rounded-full border-2 border-current border-r-transparent"
        />
      )}
      {children}
    </Comp>
  )
}

export { Button, buttonVariants }
