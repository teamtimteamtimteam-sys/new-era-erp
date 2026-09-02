'use client'

// app/operation/handovers/AcknowledgeButton.tsx
// PROC-SUPPORT-1(R4):接班人签收。
//
// 【它不问"你确定吗"】签收本来就是一个断言("我看过了"),再加一层确认
// 不会让那个断言更真。真正要防的是【签错人】,而那一条在数据库里:
// 只有这张交接班点名的接班人签得动(HANDOVER_ACK_NOT_INCOMING)。
// 【拒绝原样显示在按钮旁边】—— 那三条码的下一步动作各不相同,把它们折成
// 一句"签收失败"正是这一刀在别处反复避免的事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { acknowledgeShiftHandover } from './actions'

export default function AcknowledgeButton({ handoverId }: { handoverId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    return (
        <span className="inline-flex flex-col gap-1">
            <button
                type="button"
                disabled={isPending}
                onClick={() => startTransition(async () => {
                    setError(null)
                    const res = await acknowledgeShiftHandover(handoverId)
                    if (res.error) setError(res.error)
                    else router.refresh()
                })}
                className="text-xs border border-gray-300 px-2 py-0.5 rounded hover:bg-gray-100 disabled:text-gray-400">
                {isPending ? t('common.saving') : t('processing.handover.acknowledge')}
            </button>
            {error && <span className="text-xs text-red-700 max-w-xs">{error}</span>}
        </span>
    )
}
