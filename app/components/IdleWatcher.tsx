'use client'

// app/components/IdleWatcher.tsx
// 空闲超时的【浏览器】那一半:决定什么算"活动",并在结束前两分钟出来说话。
//
// ════════════════════════════════════════════════════════════════════════════
// 【分工:浏览器决定什么算活动,中间件只负责执行】
// 中间件跑在每一个请求上,它分不出【人在操作】与【框架在预取】。浏览器分得出,
// 因为它看得见真的按键与真的指针。所以这个文件是"什么算活动"的唯一定义,
// 而 lib/supabase/middleware.ts 只读它写下的那个 cookie —— 并且【永远不写】。
//
// 【算作活动的,穷举在下面 ACTIVITY_EVENTS 里,外加一次真实换页】
// 【不算的,同样是刻意的,而且更重要:】
//   · mousemove —— 包里的触控板、桌上一碰都会产生它。它不代表有人在干活。
//   · scroll —— 可以由程序产生(锚点跳转、focus()、自动滚动)。人真的滚动时,
//     那一下的来源是 pointer/touch,而那两个已经算了。
//   · visibilitychange / focus / online —— 这些是【环境】变化,不是人的动作。
//     一台自己醒过来的平板会发这些事件。
//   · 任何 fetch / 轮询 / 自动刷新 / websocket 心跳 —— **一条都不算。**
//     它们一旦算作活动,超时就永远不会触发,而屏幕上一切正常。
//     下面那个 setInterval 只【检查】时间,它自己【不】刷新活动时间。
// ════════════════════════════════════════════════════════════════════════════
import { useCallback, useEffect, useRef, useState } from 'react'
import { usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import {
    ACTIVITY_COOKIE,
    ACTIVITY_WRITE_THROTTLE_MS,
    IDLE_TIMEOUT_MS,
    IDLE_WARNING_MS,
} from '@/lib/session'

/** 算作活动的事件,穷举。改这一行之前先读上面那段。 */
const ACTIVITY_EVENTS = ['pointerdown', 'keydown', 'touchstart'] as const

/** 检查频率。**它只读时钟,不写活动时间** —— 见抬头。 */
const TICK_MS = 15 * 1000

function writeActivityCookie(nowMs: number) {
    // SameSite=Lax:它不是安全凭据,只是"人还在"的一个记号;伪造它只能延长
    // 自己的会话,与动一下鼠标等价。不设 HttpOnly —— 浏览器必须写得了它。
    document.cookie =
        `${ACTIVITY_COOKIE}=${nowMs}; path=/; max-age=${Math.ceil(IDLE_TIMEOUT_MS / 1000) + 60}; SameSite=Lax`
}

export default function IdleWatcher() {
    const t = useTranslations()
    const pathname = usePathname()
    const lastActivityRef = useRef<number>(Date.now())
    const lastWriteRef = useRef<number>(0)
    const [warning, setWarning] = useState<null | number>(null)   // 剩余毫秒

    /** 记一次真实活动。`force` 用于"继续留在这里"那一下 —— 它必须立刻落到 cookie。 */
    const stamp = useCallback((force = false) => {
        const now = Date.now()
        lastActivityRef.current = now
        if (force || now - lastWriteRef.current >= ACTIVITY_WRITE_THROTTLE_MS) {
            lastWriteRef.current = now
            writeActivityCookie(now)
        }
    }, [])

    // 真实的人机事件
    useEffect(() => {
        const onActivity = () => stamp()
        for (const ev of ACTIVITY_EVENTS) {
            window.addEventListener(ev, onActivity, { passive: true, capture: true })
        }
        return () => {
            for (const ev of ACTIVITY_EVENTS) {
                window.removeEventListener(ev, onActivity, { capture: true })
            }
        }
    }, [stamp])

    // 真实换页也算活动。**这是 usePathname 的变化,不是 RSC 预取** ——
    // 预取不改变 pathname,所以它到不了这里。
    useEffect(() => {
        stamp(true)
    }, [pathname, stamp])

    useEffect(() => {
        const id = setInterval(() => {
            const idle = Date.now() - lastActivityRef.current
            if (idle >= IDLE_TIMEOUT_MS) {
                // 【不在这里 signOut】签退会把认证 cookie 清掉,而中间件那条
                // "只有带着认证 cookie 才说【你的登录已经结束】"的判据就会落空 ——
                // 人会看到一张沉默的登录表单。所以这里只是【回到当前地址】,
                // 让中间件按它自己那条已经建好的路去判、去说、去清 cookie。
                window.location.assign(window.location.pathname + window.location.search)
                return
            }
            setWarning(idle >= IDLE_TIMEOUT_MS - IDLE_WARNING_MS ? IDLE_TIMEOUT_MS - idle : null)
        }, TICK_MS)
        return () => clearInterval(id)
    }, [])

    if (warning === null) return null
    const secs = Math.max(0, Math.ceil(warning / 1000))
    const mm = Math.floor(secs / 60)
    const ss = String(secs % 60).padStart(2, '0')

    // 【浮在当前页上,不是跳走】这一点是整件事的关键:人此刻可能正在一张填了
    // 一半的表单里,而这个提示【不能】把那张表单卸载掉。所以它是一层覆盖物,
    // 按下"继续留在这里"之后表单原样还在 —— 什么都没有重新挂载、什么都没有丢。
    return (
        <div
            role="alertdialog"
            aria-live="assertive"
            data-idle-warning="1"
            className="fixed inset-x-0 bottom-0 z-[9999] flex justify-center p-4 pointer-events-none"
        >
            <div className="pointer-events-auto max-w-lg w-full bg-amber-50 border-2 border-amber-400 rounded-lg shadow-lg p-4">
                <p className="font-bold text-amber-900 mb-1">{t('session.idle.title')}</p>
                <p className="text-sm text-amber-900 mb-1">
                    {t('session.idle.body', { time: `${mm}:${ss}` })}
                </p>
                <p className="text-xs text-amber-800 mb-3">{t('session.idle.reassure')}</p>
                <button
                    type="button"
                    onClick={() => { stamp(true); setWarning(null) }}
                    className="bg-amber-600 text-white px-4 py-2 rounded hover:bg-amber-700 text-sm font-medium"
                >
                    {t('session.idle.stay')}
                </button>
            </div>
        </div>
    )
}
