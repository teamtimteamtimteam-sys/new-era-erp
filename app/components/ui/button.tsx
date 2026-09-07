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
        // ★★ BTN-6(2026-09-07):虚线竖条的颜色从【描边档】换成【字色档】★★
        //   走查:「Remove lock 与 Turn GST off 的竖条一浅一深,后者几乎看不见」。
        //   查下去,两件事都与走查说的不一样,而第二件是真的缺陷:
        //   ① **不存在"两个定义"。** 全仓库 `repeating-linear-gradient` 只有这一处,
        //      两个按钮走的是同一条规则。而「Turn GST off」**根本没有这条竖条** ——
        //      它是 GstPanel 里一个不带 triggerVariant 的 <ConfirmButton>,
        //      于是 confirm-dialog 渲染的是一个【裸 <button> + 手写 className】。
        //      看起来像"浅得几乎没有"的那道线,是它自己的灰描边。
        //   ② **而这一条竖条本身确实太浅,浅到不合格。** 它此前画的是
        //      --brand-border-strong #AEBAC9 —— 一个【描边档】的值,白底 **1.97:1**。
        //      而破坏档那条实线画的是 --brand-destructive-text #AA4F48,白底 **5.36:1**。
        //   ☞ 这是本文件抬头那一课的第三次:**一个 token 在【它自己那个用法】里合规,
        //     不等于换个用法还合规。** 前两次是"淡底上的字"与"没有底的档";
        //     这一次是【一个描边值被派去承担一条语义信号】。
        //     而 §10.1 ③ 说得很清楚:这条竖条是四档里**唯一不经过颜色**的判据 ——
        //     把它画在描边的重量上,等于把唯一那条备用信道调到听不见。
        //
        //   【改成 currentColor,而不是新出一个 token】
        //   破坏档的竖条 = 破坏档的字色(bg-destructive-text 就是它的 text 色)。
        //   把同一条规矩套到撤销档上,答案就是它自己的字色 = currentColor
        //   (--brand-text #182B4B,白底 **14.13:1**)。于是两档共用**一句话**:
        //   **竖条画的是这一档自己的字色,笔法一实一虚。**
        //   ★ 虚线只占一半的墨,所以 14.13 与实线的 5.36 在眼睛里量级相当,
        //     不是"粗暴地加重"。
        //   ★ 它还自动跟着状态走:禁用时字色变 --color-disabled-text,竖条跟着淡下去
        //     —— 整个控件一起读成"关着的",不会剩一条亮线吊在那里。
        //     行内档(下面 compoundVariants)也同样正确,不必再写一遍。
        reversal:
          "border-input bg-transparent pl-3.5 text-foreground hover:bg-muted focus-visible:border-ring focus-visible:ring-ring/50 before:absolute before:inset-y-1 before:left-0 before:w-[3px] before:rounded-full before:bg-[repeating-linear-gradient(to_bottom,currentColor_0_3px,transparent_3px_6px)]",
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
        // ── ★ BTN-2(2026-09-06):【行内档】—— 一个不是盒子的按钮 ★ ──────────
        //   为什么它非有不可,而不是在 27 个调用点各写一遍 `className="h-auto p-0"`:
        //   本刀要转的 27 处链接态动作,今天是【句子里 / 表格单元格里的一段字】,
        //   没有高度、没有内边距。照 `size="default"` 转过去,每一处会变成
        //   **h=32px、左右各 10px 内边距的盒子** —— 行高当场变,而这是一次
        //   没人要求过的版式改动。§八(b):**库里缺这个能力,就先把能力加进库。**
        //
        //   ★ 它必须解掉基础层的禁用底色,否则会画出一个盒子来 ★
        //   基础层写着 `disabled:bg-disabled-bg`(#DDE7EF)。那是给【有底的档】
        //   准备的:BTN-1 量到它配 --brand-text 是 11.27:1。但行内档【没有底】,
        //   把这层底色留着,等于禁用时凭空长出一个灰色矩形 —— 一个本来只是
        //   一段字的东西,禁用后反而比启用时更像盒子。所以这里 `bg-transparent`。
        //   ☞ 与 §10.3 同一课的另一面:一个 token 在【有底的档】里合规,
        //     不等于它在【没有底的档】里还是同一件东西。
        //
        //   禁用后落在白底上的字色 = --color-disabled-text = --brand-text #182B4B
        //   实测 **14.13:1**(它取代的 `disabled:text-gray-400` 是 2.54:1,
        //   `disabled:opacity-50` 是 2.14:1)。判据仍是 BTN-1 那一条:
        //   **【清楚地不能按】,不是【淡】** —— 禁用后它读起来就是一段普通正文,
        //   没有下划线、没有色,而那正是"这里现在不是一个控件"最直白的说法。
        //
        //   `align-baseline`:行内档要和它左右的字对齐基线,不是对齐盒子中线。
        inline: "h-auto gap-1 rounded-sm p-0 align-baseline disabled:bg-transparent",
        icon: "size-8",
        "icon-xs":
          "size-6 rounded-[min(var(--radius-md),10px)] in-data-[slot=button-group]:rounded-lg [&_svg:not([class*='size-'])]:size-3",
        "icon-sm":
          "size-7 rounded-[min(var(--radius-md),12px)] in-data-[slot=button-group]:rounded-lg",
        "icon-lg": "size-9",
      },
    },
    // ════════════════════════════════════════════════════════════════════════
    // ★ BTN-3(2026-09-06)·【行内的档位】—— §八(b) 第三次运转 ★
    // ════════════════════════════════════════════════════════════════════════
    // 【为什么非加不可,而不是在调用点各写一遍】
    //   本刀要转的 25 处红/灰链接态,今天全部是**表格单元格里、或句子里的一段字**。
    //   照 size="default" 转过去,每一处会变成 h=32px 的盒子 —— BTN-2 §12.5 正是
    //   为了不做这次未经授权的版式改动才留下了一处没转。
    //   但反过来把它们留在 variant="link" 上,等于**重新发一遍 BTN-1 存在的理由**:
    //   「一个看起来像普通动作的破坏性动作,是缺陷,不是不一致。」
    //
    // 【两个档到了行内会自己散架 —— 这是实测出来的,不是推的】
    //   ① size="inline" 写着 `p-0`,而 destructive/reversal 靠 `pl-3.5` 给左竖条
    //      让出位置。p-0 一压,**竖条就画在字底下**。
    //   ② destructive 的 `bg-destructive/8` + `border-destructive/40` 在行内
    //      会把「句子里的一个词」画成一个淡红色小方块 —— 比转换前更像盒子。
    //      与 §12.4 同一课:一个 token 在【有底的档】里对,不等于它在
    //      【没有底的档】里还是同一件东西。
    //
    // 【所以行内档保留什么、丢掉什么 —— 判据是 §10.1 的第 ③ 条】
    //   保留:**3px 左竖条,实线 / 虚线**。那一条是纯几何,不经过颜色,
    //         也是这两个档在行内**唯一**还分得开的判据。
    //   丢掉:底与描边(它们只对盒子成立)。
    //   字色:destructive 用 --brand-destructive-text。实测 #AA4F48 on white
    //         = **5.356:1**,而它取代的 text-red-600 是 **4.829:1** ——
    //         **这一次转换【提高】了对比度**(BTN-2 的蓝色那次是降低)。
    //   hover:underline:今天这 25 处全部有,行内保留它,悬停反馈一字不改。
    // ════════════════════════════════════════════════════════════════════════
    compoundVariants: [
      {
        // 行内破坏档:实线竖条留着,底与描边去掉。
        variant: "destructive",
        size: "inline",
        className:
          "border-transparent bg-transparent pl-2 hover:bg-transparent hover:underline focus-visible:border-transparent before:inset-y-0.5",
      },
      {
        // 行内撤销档:虚线竖条留着 —— 与上面同一处几何,一实一虚。
        variant: "reversal",
        size: "inline",
        className:
          "border-transparent bg-transparent pl-2 hover:bg-transparent hover:underline focus-visible:border-transparent before:inset-y-0.5",
      },
      {
        // 行内次档:没有竖条(次档从来就没有),只剩 400 字重与正文色。
        // 它与 link 的差别是【颜色与字重】:link 是 ocean 500,它是正文色 400。
        // 草稿行上的「移除」正是这一档:什么都还没存过,红色在这里是假话。
        variant: "secondary",
        size: "inline",
        className: "border-transparent hover:bg-transparent hover:underline",
      },
    ],
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
      {/* ★★ BTN-5(2026-09-06):这一行是【一条量出来的库缺陷】的修法 ★★
          原来的写法把转圈和 children 【并列】摆在这里:

              {busy && (<span … />)}
              {children}

          `busy` 为 false 时,第一项求值成 `false` —— 而 `false` 仍然【是一个
          children 数组元素】。于是 asChild 那条路上 Slot 收到的是【两个】孩子,
          它当场抛:`Slot failed to slot onto its children. Expected a single
          React element child or Slottable.`

          ☞ **所以 asChild 在这棵树上【从来没有能用过】。** 委托书写的是
            「机制已经存在,只是没有调用点」;实测更准的说法是
            **「它没有调用点,是因为它一用就抛」** —— 零调用点不是"没人想到用",
            是"用了就红,于是没有人留下过一个"。
          ★ 这也是一条「没有任何东西验过它」的直接后果:一个没有调用点的能力,
            与一个坏掉的能力,在任何检查的退出码上都是同一个字节。

          改法把两种形态分开:pending 时才构造那个 fragment,否则【原样传 children】。
          ★ 非 asChild 且非 pending 的那条路,渲染结果一个字节都没变
            (`{false}{children}` 与 `{children}` 画出来的 DOM 相同)—— 187 个
            已经转过去的按钮因此不受影响。 */}
      {busy ? (
        <>
          <span
            aria-hidden
            className="base-spin inline-block size-3.5 rounded-full border-2 border-current border-r-transparent"
          />
          {children}
        </>
      ) : (
        children
      )}
    </Comp>
  )
}

export { Button, buttonVariants }
