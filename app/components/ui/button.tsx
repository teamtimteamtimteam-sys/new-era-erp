import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"
import { Slot } from "radix-ui"

import { cn } from "@/lib/utils"

// ════════════════════════════════════════════════════════════════════════════
// BTN-1(2026-09-06)· 档位、禁用态、以及【两个量出来的库自身缺陷】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么禁用态不是 opacity-50 —— 这是本刀改的第一件事,而它是一条缺陷】
//   原来的写法是 `disabled:opacity-50`,把整个按钮连底带字一起调淡。实测:
//       default 变体禁用后 → 底 #80bfd6,字 #c0dfeb,**对比度 1.45:1**
//   而它要取代的那 62 处手写按钮用的是 `disabled:bg-gray-400` → **2.54:1**。
//   **也就是说照原样转换,会让禁用态比现在【更看不清】** —— 而本仓库
//   docs/silent-disable-inventory.md 里还有【9 处】只灰不说的提交钮在等着修。
//   一个看不清的灰钮,把"系统在拦你"变成"这里好像什么都没有"。
//
//   所以禁用档【有自己的颜色】,不是把按钮调淡:
//       底 --brand-disabled-bg #DDE7EF · 字 --brand-text #182B4B → **11.27:1**
//   ★ 判据是【清楚地不能按】,不是【淡】。淡=可能没加载完;平+灰底=明确关着。
//
// 【第二个缺陷:destructive 的字画在淡底上,低于 AA】
//   --brand-destructive-fill 的 4.53:1 是**对着白底**量的,而这个变体把字画在
//   一层 destructive 淡底上。实测 #B75B53 on #F9F2F1 = **4.01:1,不合格**。
//   已另出 --brand-destructive-text(#AA4F48,同一淡底上 4.85:1)。
//   ☞ 一个 token 标着"合规"不等于它在【这个用法】里合规 —— 底换了,数就变了。
//
// 【★ 档位靠什么分开 —— 颜色是【最后】一条,不是第一条 ★】
//   Tim 的裁定:一个只能靠颜色分辨的破坏性动作,是把最危险的一格
//   押在【一部分人根本用不了的信道】上。所以四档在颜色之外还差着:
//     ① 有没有实底  —— 只有 primary 是实心的。一个区域只该有一个实心钮。
//     ② 字重        —— 会提交的档 500,secondary 400。
//     ③ ★ 左侧竖条 —— destructive 实线 3px,reversal 虚线 3px,别的档没有。
//                      这一条是【纯几何】,不经过颜色。
//     ④ 动词形状    —— destructive 是 Delete/Void;reversal 是 Un-/Re-。
//
// 【★ reversal 这一档为什么存在(Tim 在 BTN-1 闸上裁定)★】
//   实测 57 个按钮做的是"撤销一个已经过账的状态":Reopen · Unpost · Unapply ·
//   Unreconcile · Unmatch · Turn GST off。**它们不删任何东西,审计痕迹全留着。**
//   把它们画成 destructive 红,等于教会操作员"红=我会丢数据" ——
//   而那句话在他第一次点 Reopen 时就是【假的】。一条被教错的规则比没有更坏。
//   它们也不是 primary:没有任何一页是为了 Reopen 而存在的。
// ════════════════════════════════════════════════════════════════════════════
const buttonVariants = cva(
  "group/button relative inline-flex shrink-0 items-center justify-center rounded-lg border border-transparent bg-clip-padding text-sm font-medium whitespace-nowrap transition-all outline-none select-none focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 active:not-aria-[haspopup]:translate-y-px disabled:pointer-events-none disabled:border-transparent disabled:bg-disabled-bg disabled:text-disabled-text disabled:shadow-none disabled:before:hidden aria-invalid:border-destructive aria-invalid:ring-3 aria-invalid:ring-destructive/20 dark:aria-invalid:border-destructive/50 dark:aria-invalid:ring-destructive/40 [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        // ── 主档:一个区域只该有一个实心钮 ──────────────────────────────
        default:
          "bg-primary text-primary-foreground hover:bg-primary-hover active:bg-primary-active",
        outline:
          "border-border bg-background hover:bg-muted hover:text-foreground aria-expanded:bg-muted aria-expanded:text-foreground dark:border-input dark:bg-input/30 dark:hover:bg-input/50",
        // ── 次档:唯一一个【字重更轻】的档(400),不靠颜色也读得出它是次要的 ──
        secondary:
          "border-input bg-transparent font-normal text-foreground hover:bg-muted aria-expanded:bg-muted aria-expanded:text-foreground",
        ghost:
          "hover:bg-muted hover:text-foreground aria-expanded:bg-muted aria-expanded:text-foreground dark:hover:bg-muted/50",
        // ── 破坏档:淡底 + 合规字色 + 【实线左竖条】(几何,不经过颜色)──────
        destructive:
          "border-destructive/40 bg-destructive/8 pl-3.5 text-destructive-text hover:bg-destructive/16 focus-visible:border-destructive/40 focus-visible:ring-destructive/20 before:absolute before:inset-y-1 before:left-0 before:w-[3px] before:rounded-full before:bg-destructive-text",
        // ── ★ 撤销档:虚线左竖条 —— 与破坏档【同位置、不同笔法】★ ───────────
        //    同一处几何,一实一虚:并排时不看颜色也分得开。
        reversal:
          "border-input bg-transparent pl-3.5 text-foreground hover:bg-muted focus-visible:border-ring focus-visible:ring-ring/50 before:absolute before:inset-y-1 before:left-0 before:w-[3px] before:rounded-full before:bg-[repeating-linear-gradient(to_bottom,var(--brand-border-strong)_0_3px,transparent_3px_6px)]",
        // ── 警告档:实心。不是主动作,是【系统在告诉你一件正在发生的事】────
        //    唯一用到 --brand-warning-* 的地方(闲置超时对话框)。出处见 brand-tokens.css。
        warning:
          "bg-warning text-warning-foreground hover:bg-warning-hover active:bg-warning-active focus-visible:border-warning focus-visible:ring-warning/30",
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
