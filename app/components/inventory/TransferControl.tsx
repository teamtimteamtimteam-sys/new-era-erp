'use client'

// IOD-1:把一个桶的货搬到另一个库位。一个来源桶一组控件。
//
// 【状态原样带过去】—— 转移搬的是位置,不是状态。一批被扣住的货换个货架
// 仍然是被扣住的,所以这里没有"顺便放开"的选项:那是释放,是另一个动作。
// 后果写在按钮旁边,禁用条件各自带一句话。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { transferStockAction } from './stockActions'

export type LocationOption = { id: string; code: string; name: string }

export default function TransferControl({
    inboundBatchId,
    outputBatchId,
    fromLocationId,
    stockStatus,
    have,
    unit,
    locations,
}: {
    inboundBatchId: string | null
    outputBatchId: string | null
    fromLocationId: string | null
    stockStatus: 'available' | 'on_hold'
    have: number
    unit: string
    locations: LocationOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [qty, setQty] = useState('')
    const [to, setTo] = useState('')
    const [note, setNote] = useState('')

    // 目的地不能是来源自己 —— 服务端会点名拒(IOD_TRANSFER_SAME_LOCATION),
    // 但没必要让人先撞一次:把它从下拉里去掉。
    const targets = locations.filter((l) => l.id !== fromLocationId)

    const blocked =
        have <= 0 ? 'noStock'
            : targets.length === 0 ? 'noTargets'
                : qty.trim() === '' ? 'noQty'
                    : to === '' ? 'noTarget'
                        : null

    function onTransfer() {
        setError('')
        startTransition(async () => {
            const res = await transferStockAction(inboundBatchId, outputBatchId, fromLocationId, to, qty, stockStatus, note)
            if (res.error) setError(res.error)
            else { setQty(''); setTo(''); setNote(''); router.refresh() }
        })
    }

    return (
        <div className="mt-3 pt-3 border-t">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-2">
                <div>
                    <label className="block text-xs text-gray-600 mb-1">{t('stock.transferQty', { unit })}</label>
                    <DecimalInput value={qty} onChange={setQty} className="w-24 border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <div className="flex-1 min-w-[11rem]">
                    <label className="block text-xs text-gray-600 mb-1">{t('stock.transferTo')}</label>
                    <select
                        value={to}
                        onChange={(e) => setTo(e.target.value)}
                        className="w-full border border-gray-300 px-2 py-1 rounded text-sm"
                    >
                        <option value="">{t('stock.transferPick')}</option>
                        {targets.map((l) => (
                            <option key={l.id} value={l.id}>{l.code} — {l.name}</option>
                        ))}
                    </select>
                </div>
                <div className="flex-1 min-w-[10rem]">
                    <label className="block text-xs text-gray-600 mb-1">{t('stock.transferNote')}</label>
                    <input type="text" value={note} onChange={(e) => setNote(e.target.value)}
                           className="w-full border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <button
                    type="button"
                    onClick={onTransfer}
                    disabled={isPending || blocked !== null}
                    className="border border-blue-400 text-blue-800 px-3 py-1 rounded hover:bg-blue-50 text-sm disabled:opacity-50"
                >
                    {isPending ? t('common.saving') : t('stock.transfer')}
                </button>
            </div>
            {/* 后果 —— 挨着按钮。状态保持这件事必须说出来,否则搬完一批暂扣的货
                之后,人会以为它顺便被放开了。 */}
            <p className="text-xs text-gray-500 mt-1">
                {stockStatus === 'on_hold' ? t('stock.transferConsequenceHeld') : t('stock.transferConsequence')}
            </p>
            {blocked === 'noStock' && <p className="text-xs text-gray-500 mt-1">{t('stock.transferBlockedNoStock')}</p>}
            {blocked === 'noTargets' && <p className="text-xs text-amber-800 mt-1">{t('stock.transferBlockedNoTargets')}</p>}
            {blocked === 'noQty' && <p className="text-xs text-gray-500 mt-1">{t('stock.blockedNoQty')}</p>}
            {blocked === 'noTarget' && <p className="text-xs text-gray-500 mt-1">{t('stock.transferBlockedNoTarget')}</p>}
        </div>
    )
}
