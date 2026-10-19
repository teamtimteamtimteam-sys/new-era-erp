'use client'

// MES-8b-2(2026-10-17,MES-8 Step 0 Q20,Tim):大屏的「refreshed at hh:mm」与刷新钮,以及 V28 给了之后的自动刷新。
//   ★ V28 没给时【不自动刷新】—— 一个没人说过的间隔不由这里猜(Q20)。给了之后每 refreshSeconds 秒 router.refresh() 一次。
//   ★ 刷新【不算活动】:它不写活动 cookie(那只有 IdleWatcher 写,只认真的按键 / 指针 / 换页)。一块大屏不被登出,
//     靠的是服务端的豁免(session_is_floor_display_only),不是靠它自己的轮询把会话续下去 —— 一个持别的码的会话打开这一页,
//     自动刷新照样会在空闲满三十分钟时被中间件登出。
import { useEffect, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function RefreshControls({ refreshedAt, refreshSeconds }: { refreshedAt: string; refreshSeconds: number | null }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()

    useEffect(() => {
        if (refreshSeconds === null || refreshSeconds <= 0) return
        const id = setInterval(() => startTransition(() => router.refresh()), refreshSeconds * 1000)
        return () => clearInterval(id)
    }, [refreshSeconds, router])

    return (
        <div className="flex flex-wrap items-center gap-3">
            <p className="text-lg text-gray-600" data-value="display-refreshed-at">{t('display.refreshedAt', { time: refreshedAt })}</p>
            <Button type="button" variant="secondary" disabled={pending} data-action="display-refresh"
                onClick={() => startTransition(() => router.refresh())}>
                {pending ? t('display.refreshing') : t('display.refresh')}
            </Button>
            <p className="text-sm text-gray-500 basis-full" data-value="display-auto-refresh">
                {refreshSeconds === null ? t('display.autoRefreshNotSet') : t('display.autoRefreshEvery', { seconds: String(refreshSeconds) })}
            </p>
        </div>
    )
}
