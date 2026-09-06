'use client'

// STK-1:暂扣 / 释放控件。一个库位一组。
//
// 【两个不对称,都是有意的】
//   * 暂扣要理由(它限制别人,过两天要说得清为什么);释放的备注可选
//     (放开只是让事情回到常态,强制一个没人真想写的字段只会换来一堆 "ok")。
//   * 因此按钮的禁用条件也不同,而【每一个禁用条件旁边都写着它为什么禁】——
//     一个灰掉却不说话的按钮,和一个坏掉的按钮在屏幕上是同一样东西。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { holdStockAction, releaseStockAction } from './stockActions'
import { Button } from '@/app/components/ui/button'

export default function HoldReleaseControls({
    inboundBatchId,
    outputBatchId,
    locationId,
    available,
    held,
    unit,
}: {
    inboundBatchId: string | null
    outputBatchId: string | null
    locationId: string | null
    available: number
    held: number
    unit: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [holdQty, setHoldQty] = useState('')
    const [holdReason, setHoldReason] = useState('')
    const [relQty, setRelQty] = useState('')
    const [relNote, setRelNote] = useState('')

    const holdBlocked =
        available <= 0 ? 'noAvailable' : holdQty.trim() === '' ? 'noQty' : holdReason.trim() === '' ? 'noReason' : null
    const releaseBlocked = held <= 0 ? 'noHeld' : relQty.trim() === '' ? 'noQty' : null

    function run(fn: () => Promise<{ error?: string }>) {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res.error) setError(res.error)
            else {
                setHoldQty(''); setHoldReason(''); setRelQty(''); setRelNote('')
                router.refresh()
            }
        })
    }

    return (
        <div className="mt-3 border-t pt-3 space-y-4">
            {error && <p className="text-sm text-red-600">{error}</p>}

            {/* ── 暂扣 ── */}
            <div>
                <div className="flex flex-wrap items-end gap-2">
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('stock.holdQty', { unit })}</label>
                        <DecimalInput
                            value={holdQty}
                            onChange={setHoldQty}
                            className="w-28 border border-gray-300 px-2 py-1 rounded text-sm"
                        />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className="block text-xs text-gray-600 mb-1">
                            {t('stock.holdReason')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="text"
                            value={holdReason}
                            onChange={(e) => setHoldReason(e.target.value)}
                            className="w-full border border-gray-300 px-2 py-1 rounded text-sm"
                        />
                    </div>
                    <Button variant="secondary" size="sm" className="text-sm"
                        type="button"
                        disabled={isPending || holdBlocked !== null}
                        onClick={() => run(() => holdStockAction(inboundBatchId, outputBatchId, locationId, holdQty, holdReason))}>
                        {isPending ? t('common.saving') : t('stock.hold')}
                    </Button>
                </div>
                {/* 后果 —— 挨着按钮。以及每一个禁用条件各自的那句话。 */}
                <p className="text-xs text-gray-500 mt-1">{t('stock.holdConsequence')}</p>
                {holdBlocked === 'noAvailable' && <p className="text-xs text-amber-800 mt-1">{t('stock.holdBlockedNoAvailable')}</p>}
                {holdBlocked === 'noQty' && <p className="text-xs text-gray-500 mt-1">{t('stock.blockedNoQty')}</p>}
                {holdBlocked === 'noReason' && <p className="text-xs text-gray-500 mt-1">{t('stock.holdBlockedNoReason')}</p>}
            </div>

            {/* ── 释放 ── */}
            <div>
                <div className="flex flex-wrap items-end gap-2">
                    <div>
                        <label className="block text-xs text-gray-600 mb-1">{t('stock.releaseQty', { unit })}</label>
                        <DecimalInput
                            value={relQty}
                            onChange={setRelQty}
                            className="w-28 border border-gray-300 px-2 py-1 rounded text-sm"
                        />
                    </div>
                    <div className="flex-1 min-w-[12rem]">
                        <label className="block text-xs text-gray-600 mb-1">{t('stock.releaseNote')}</label>
                        <input
                            type="text"
                            value={relNote}
                            onChange={(e) => setRelNote(e.target.value)}
                            className="w-full border border-gray-300 px-2 py-1 rounded text-sm"
                        />
                    </div>
                    <Button variant="secondary" size="sm"
                        type="button"
                        disabled={isPending || releaseBlocked !== null}
                        onClick={() => run(() => releaseStockAction(inboundBatchId, outputBatchId, locationId, relQty, relNote))}
                    >
                        {isPending ? t('common.saving') : t('stock.release')}
                    </Button>
                </div>
                <p className="text-xs text-gray-500 mt-1">{t('stock.releaseConsequence')}</p>
                {releaseBlocked === 'noHeld' && <p className="text-xs text-gray-500 mt-1">{t('stock.releaseBlockedNoHeld')}</p>}
                {releaseBlocked === 'noQty' && <p className="text-xs text-gray-500 mt-1">{t('stock.blockedNoQty')}</p>}
            </div>
        </div>
    )
}
