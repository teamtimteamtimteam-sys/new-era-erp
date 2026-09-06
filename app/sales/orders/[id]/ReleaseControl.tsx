'use client'

// SO-2:一条预留上的【释放】。
//
// 【理由必填,而这与暂扣的不对称是有意的】release_stock(放开暂扣)的备注是
// 可选的,因为那只是让事情回到常态;这里不是 —— 撤回一个【已经做出的承诺】
// 本身就是一个需要解释的动作。服务端按名拒 SO_RELEASE_REASON_REQUIRED,
// 这里在按下之前就把钮禁掉,不让人先撞一次。
//
// 【数量留空 = 整笔释放】,不是 0。部分释放在服务端做成"整笔释放 + 就地重新
// 预留剩余",所以这个框里填 25 的意思是"放回 25",剩下的仍然许着 —— 提示语
// 说的就是这件事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { releaseReservation } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function ReleaseControl({
    orderId,
    reservationId,
    outputBatchId,
    qty,
    unit,
}: {
    orderId: string
    reservationId: string
    qty: number
    unit: string
    outputBatchId: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [error, setError] = useState('')
    const [reason, setReason] = useState('')
    const [amount, setAmount] = useState('')

    const amountN = Number(amount)
    const amountBad = amount.trim() !== '' && (Number.isNaN(amountN) || amountN <= 0 || amountN > qty)
    const blocked = reason.trim() === '' || amountBad

    function go() {
        setError('')
        startTransition(async () => {
            const res = await releaseReservation(orderId, reservationId, outputBatchId, amount, reason)
            if (res.error) setError(res.error)
            else {
                setOpen(false)
                setReason('')
                setAmount('')
                router.refresh()
            }
        })
    }

    if (!open) {
        return (
            <Button
                variant="link"
                size="inline"
                type="button"
                onClick={() => setOpen(true)}
                className="text-xs"
            >
                {t('sales.reserve.release')}
            </Button>
        )
    }

    return (
        <div className="w-full mt-1 border border-gray-300 rounded p-2">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-2">
                <div className="w-36">
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('sales.reserve.releaseQty', { unit })}
                    </label>
                    <input
                        type="number"
                        step="any"
                        min="0"
                        max={qty}
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        placeholder={String(qty)}
                        className="w-full border border-gray-300 px-2 py-1 rounded text-sm"
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block text-xs text-gray-600 mb-1">{t('sales.reserve.releaseReason')}</label>
                    <input
                        type="text"
                        value={reason}
                        onChange={(e) => setReason(e.target.value)}
                        className="w-full border border-gray-300 px-2 py-1 rounded text-sm"
                    />
                </div>
                <Button variant="secondary" size="sm"
                    type="button"
                    onClick={go}
                    disabled={isPending || blocked}
                >
                    {isPending ? t('common.saving') : t('sales.reserve.release')}
                </Button>
                <Button
                    variant="ghost"
                    size="sm"
                    type="button"
                    onClick={() => setOpen(false)}
                >
                    {t('common.cancel')}
                </Button>
            </div>
            <p className="text-xs text-gray-500 mt-1">
                {amountBad
                    ? t('sales.reserve.releaseOver', { have: String(qty) })
                    : reason.trim() === ''
                      ? t('sales.reserve.releaseNeedsReason')
                      : t('sales.reserve.releaseConsequence')}
            </p>
        </div>
    )
}
