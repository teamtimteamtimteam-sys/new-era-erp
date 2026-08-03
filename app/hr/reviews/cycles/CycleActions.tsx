'use client'

// 开轮 / 关轮。开轮铺单据(open_review_cycle,幂等,重按不会多铺);
// 关轮只是记下"这一轮结束了"。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { closeCycle, openCycle } from '../actions'

export default function CycleActions({ cycleId, status }: { cycleId: string; status: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    return (
        <span className="inline-flex items-center gap-2">
            {status === 'draft' && (
                <button
                    type="button"
                    onClick={() => run(() => openCycle(cycleId))}
                    disabled={pending}
                    className="bg-blue-600 text-white px-3 py-1 rounded hover:bg-blue-700 text-sm disabled:opacity-50"
                >
                    {t('reviews.openCycle')}
                </button>
            )}
            {status === 'open' && (
                <>
                    {/* 幂等重跑:新入职转正的人补一份草稿 */}
                    <button
                        type="button"
                        onClick={() => run(() => openCycle(cycleId))}
                        disabled={pending}
                        className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
                    >
                        {t('reviews.rerunCycle')}
                    </button>
                    <button
                        type="button"
                        onClick={() => run(() => closeCycle(cycleId))}
                        disabled={pending}
                        className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
                    >
                        {t('reviews.closeCycle')}
                    </button>
                </>
            )}
            {error && <span className="text-xs text-red-700">{error}</span>}
        </span>
    )
}
