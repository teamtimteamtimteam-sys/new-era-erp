'use client'

// ════════════════════════════════════════════════════════════════════════════
// LOGIN-1 · 提交中的那一段(2026-09-02)
//
// 【这一页此前【没有】提交态】表单直接 action={login},服务器动作跑多久屏幕上
// 就沉默多久。在手机上、在移动网络下,那是这一屏最常见的一次失败:
// **人不知道自己那一下点上没有,于是再点一次。**
//
// 【为什么只有按钮是 client】useFormStatus 必须在 <form> 内部的组件里读。
// 把它单独切出来,页面与动作都还留在服务端 —— 客户端包里只多了这一个按钮。
//
// 【disabled 与 aria-busy 一起给】disabled 挡住第二次提交(那是真正要防的事);
// aria-busy 告诉读屏软件「这不是坏了,是在做」。少任何一个都说不全。
// 而按钮的【可及名字】跟着换成「登录中…」—— 焦点正在它身上,名字一变就会被念出来。
// ════════════════════════════════════════════════════════════════════════════

import { useFormStatus } from 'react-dom'
import { Button } from '@/app/components/ui/button'

export default function SubmitButton({
    label,
    pendingLabel,
}: {
    label: string
    pendingLabel: string
}) {
    const { pending } = useFormStatus()
    return (
        <Button
            type="submit"
            disabled={pending}
            aria-busy={pending}
            // h-11 = 44px:shadcn 的 default 是 h-8(32px),那对【手机上的主操作】太小。
            // 44px 是 Apple HIG 与 WCAG 2.5.5 都指的那个数。这一条是 R7 的「先能用」。
            // 焦点环单独指定:vendored 的 shadcn 用 ring-ring/50(半透明),
            // 实测那一档对白底只有 1.6:1,达不到 1.4.11 的 3:1。这里换成【实心品牌色】。
            className="h-11 w-full text-[15px] focus-visible:ring-2 focus-visible:ring-[color:var(--brand-ocean)] focus-visible:ring-offset-2 focus-visible:ring-offset-[color:var(--brand-surface)]"
        >
            {pending ? pendingLabel : label}
        </Button>
    )
}
