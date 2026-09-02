'use client'

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 状态反馈里【CSS 做不到的那一件】+ 加载占位
// ════════════════════════════════════════════════════════════════════════════
// 四种状态里三种是纯 CSS(见 app/base-motion.css 的抬头)。只有这一种不是:
//
// ★ 数字变了 —— 这需要一个逐帧循环,而 CSS 没有 ★
//   CSS 能过渡颜色、位置、透明度,但过渡不了【一个数从 812 走到 1,043】:
//   要走的是 textContent,不是样式属性。这就是本刀唯一一处用 JS 做动效的地方,
//   而它是 requestAnimationFrame 的 ~15 行 —— 不是一个 40KB 的依赖。
//   **这一行就是"motion.dev 有没有挣到它的位置"的全部答案:它要顶替的,是这 15 行。**
//
// ★ 这个状态为什么值得反馈 ★
//   一个总数悄悄从 812 变成 1,043,和它一直是 1,043,在屏幕上一模一样。
//   人如果没看见它【变】,就不知道自己刚才那一步生效了 ——
//   而这正是本仓库反复记的那个形状:一次成功的写,屏幕上没有任何证据。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { cn } from '@/lib/utils'

const prefersReduced = () =>
    typeof window !== 'undefined' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches

/**
 * 一个【走过去】的数字。
 *
 * 【减弱动效之下它直接落在终值】—— 关掉的是"走"这个过程,不是这个数。
 * 【首次渲染不走】第一次看到这个数不是"它变了",是"它就是这个数";
 * 开屏时满页数字一起跑,正是 R1 说的那种装饰。
 */
export function CountUp({
    value, format = (n) => n.toLocaleString('zh-Hans-CN'), durationMs = 420, className, ...props
}: React.ComponentProps<'span'> & {
    value: number
    format?: (n: number) => string
    durationMs?: number
}) {
    const [shown, setShown] = React.useState(value)
    const from = React.useRef(value)
    const first = React.useRef(true)

    React.useEffect(() => {
        if (first.current) { first.current = false; from.current = value; setShown(value); return }
        if (prefersReduced() || durationMs <= 0) { from.current = value; setShown(value); return }
        const start = performance.now()
        const a = from.current, b = value
        let raf = 0
        const tick = (t: number) => {
            const p = Math.min(1, (t - start) / durationMs)
            // easeOutCubic —— 快起慢收,读起来像"落位",不像"匀速爬"。
            const e = 1 - Math.pow(1 - p, 3)
            setShown(a + (b - a) * e)
            if (p < 1) raf = requestAnimationFrame(tick)
            else from.current = b
        }
        raf = requestAnimationFrame(tick)
        return () => cancelAnimationFrame(raf)
    }, [value, durationMs])

    return (
        <span className={cn('tabular-nums', className)} {...props}>
            {format(Math.round(shown))}
        </span>
    )
}

/**
 * 加载占位。
 *
 * 【为什么它值得存在】"在取数"和"取回来是空的"在屏幕上长得一模一样,
 * 而这两句话完全不同 —— 本仓库为「空集不是失败」这个形状记过很多次账。
 * 骨架说的是【还没到】,空态说的是【到了,是空的】。
 */
export function Skeleton({ className, ...props }: React.ComponentProps<'div'>) {
    return (
        <div
            data-slot="skeleton"
            aria-hidden
            className={cn('base-skeleton rounded-[var(--brand-radius)]', className)}
            {...props}
        />
    )
}

/**
 * 成功一闪 —— 把 `base-flash-ok` 挂在刚刚写成功的那块内容上。
 *
 * 【为什么是一个 hook 而不是一个组件】成功要闪的是【本来就在那儿的那一块】
 * (一行、一张卡、一个数),不是一个新套上去的盒子。
 * 返回的 key 变化会让 React 重挂那个节点,于是 CSS 动画重新跑一遍。
 */
export function useFlashOnChange(dep: unknown) {
    const [n, setN] = React.useState(0)
    const first = React.useRef(true)
    React.useEffect(() => {
        if (first.current) { first.current = false; return }
        setN((x) => x + 1)
    }, [dep])
    return { flashKey: n, flashClass: n > 0 ? 'base-flash-ok' : undefined }
}
