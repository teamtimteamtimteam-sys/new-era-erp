'use client'

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 校验失败时【把眼睛带过去】
// ════════════════════════════════════════════════════════════════════════════
// 【这个状态为什么值得反馈】表单被拒的时候,焦点常常不在出错的那一格 ——
// 一整屏里多了一道红边,人要自己找。颜色是静态的,而一次极短的位移会【带着眼睛过去】。
// 两下、3px、260ms:再多一点就是卡通,而卡通用到第三天就只剩烦人(R1)。
//
// 【只在"变成"无效的那一刻动,不是"是无效的"就一直动】——
// 后者会让一个填错的表单永远在抖。
//
// ★★ 它默认【关着】,而这不是保守,是 R5 逼出来的 ★★
//   /login 是【已经上线的一页】(LOGIN-1 转换过),而它两个输入框都写着
//   `aria-invalid={fieldsInvalid || undefined}` —— 也就是说,如果这条动效默认打开,
//   **本刀就在一个已上线页面上改了行为**:登录失败时输入框会开始抖。
//   R5 说 187 页一个像素都不许变,这一条正好会撞上去。
//   所以它是一个显式开关(`nudgeOnInvalid`),默认 false ——
//   与 R4 对排序/分页那四个开关的处置逐字同一条:**能力建好,但不自动生效。**
//
// 【减弱动效之下不动,但红边、aria-invalid 一个都不少】关掉的是动,不是这句话。
//
// 【为什么它成了客户端组件】它要知道 aria-invalid 【什么时候】翻过来,
// 那需要一次 effect。输入框本来就活在交互里,这不构成新的约束。

import * as React from "react"

import { cn } from "@/lib/utils"
// ★ INPUT-2(2026-09-10):样式的【来处】搬到了 control-style.ts —— 手搓的原生控件、
//   勾选框、单选框、`<DataTable>` 的筛选框读的是同一处。**本组件发出去的 class 串
//   逐字节没有变**(顺序也没变;INPUT-2 用 `git show HEAD:` 的原串逐字比过)。
import { INPUT_COMPONENT_CLASS } from "@/app/components/ui/control-style"

function Input({
  className,
  type,
  nudgeOnInvalid = false,
  ...props
}: React.ComponentProps<"input"> & {
  /** 校验失败时轻推一下。默认关 —— 见抬头:打开它会改变 /login 现在的行为。 */
  nudgeOnInvalid?: boolean
}) {
  const invalid =
    nudgeOnInvalid &&
    (props["aria-invalid"] === true || props["aria-invalid"] === "true")
  const [nudge, setNudge] = React.useState(false)
  const was = React.useRef(invalid)
  React.useEffect(() => {
    if (invalid && !was.current) {
      setNudge(true)
      const t = setTimeout(() => setNudge(false), 560)
      was.current = invalid
      return () => clearTimeout(t)
    }
    was.current = invalid
  }, [invalid])

  return (
    <input
      type={type}
      data-slot="input"
      className={cn(
        INPUT_COMPONENT_CLASS,
        nudge && "base-nudge-err",
        className
      )}
      {...props}
    />
  )
}

export { Input }
