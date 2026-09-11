import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { Slot } from "radix-ui"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "group/badge inline-flex h-5 w-fit shrink-0 items-center justify-center gap-1 overflow-hidden rounded-4xl border border-transparent px-2 py-0.5 text-xs font-medium whitespace-nowrap transition-all focus-visible:border-ring focus-visible:ring-[3px] focus-visible:ring-ring/50 has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 aria-invalid:border-destructive aria-invalid:ring-destructive/20 dark:aria-invalid:ring-destructive/40 [&>svg]:pointer-events-none [&>svg]:size-3!",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground [a]:hover:bg-primary/80",
        secondary:
          "bg-secondary text-secondary-foreground [a]:hover:bg-secondary/80",
        destructive:
          "bg-destructive/10 text-destructive focus-visible:ring-destructive/20 dark:bg-destructive/20 dark:focus-visible:ring-destructive/40 [a]:hover:bg-destructive/20",
        // ★★ FONT-2(2026-09-11, Tim Q5)· `text-foreground` → `--brand-text` ★★
        //   `text-foreground` 指着 `--foreground` #171717,而 `body` 从 FONT-1 起
        //   已经是 `--brand-text` #182B4B。★ Tim 的裁定:队列把 `alert.tsx` 点名
        //   给了【开着的】ALERT-2b 那一刀,所以那一个不碰;而 `badge.tsx`
        //   **没有归给任何一刀**,于是它这一处跟着归一。
        //   ⚠ 照直说它在屏幕上的效果:★ **这个组件今天【零个产品使用者】**
        //     (`scripts/check-base-isolation.mjs` 的 GUARDED 里就有它,而那道闸
        //     守的正是"还没有人用它")。所以这一处改动 **UNMEASURED —— 它今天
        //     不渲染在任何一条路由上**。它是给将来第一个采用者准备的。
        outline:
          "border-border text-[color:var(--brand-text)] [a]:hover:bg-muted [a]:hover:text-muted-foreground",
        ghost:
          "hover:bg-muted hover:text-muted-foreground dark:hover:bg-muted/50",
        link: "text-primary underline-offset-4 hover:underline",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

function Badge({
  className,
  variant = "default",
  asChild = false,
  ...props
}: React.ComponentProps<"span"> &
  VariantProps<typeof badgeVariants> & { asChild?: boolean }) {
  const Comp = asChild ? Slot.Root : "span"

  return (
    <Comp
      data-slot="badge"
      data-variant={variant}
      className={cn(badgeVariants({ variant }), className)}
      {...props}
    />
  )
}

export { Badge, badgeVariants }
