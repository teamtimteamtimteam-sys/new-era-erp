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
    // SO-2:第三个桶。committed 的转移【只允许整桶】—— 服务端按名拒
    // IOD_TRANSFER_COMMITTED_PARTIAL(部分搬会让预留行与流水对不上)。
    stockStatus: 'available' | 'on_hold' | 'committed'
    have: number
    unit: string
    locations: LocationOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    // IOD-2:入腿的落地告警。与 error 分开 —— 有 error 时什么都没搬,
    // 有 warnings 时【货已经搬过去了】,只是有个决定没人做过。
    const [warnings, setWarnings] = useState<string[]>([])
    const [qty, setQty] = useState('')
    const [to, setTo] = useState('')
    const [note, setNote] = useState('')

    // 目的地不能是来源自己 —— 服务端会点名拒(IOD_TRANSFER_SAME_LOCATION),
    // 但没必要让人先撞一次:把它从下拉里去掉。
    const targets = locations.filter((l) => l.id !== fromLocationId)

    // SO-2:committed 只能整桶搬 —— 页面在按下【之前】就说这一条,而不是
    // 让人撞一次服务端的拒绝("不给人看见一个必然被拒的按钮")。
    const partialCommitted =
        stockStatus === 'committed' && qty.trim() !== '' && Number(qty) !== have

    const blocked =
        have <= 0 ? 'noStock'
            : targets.length === 0 ? 'noTargets'
                : qty.trim() === '' ? 'noQty'
                    : to === '' ? 'noTarget'
                        : partialCommitted ? 'partialCommitted'
                            : null

    function onTransfer() {
        setError('')
        setWarnings([])
        startTransition(async () => {
            const res = await transferStockAction(inboundBatchId, outputBatchId, fromLocationId, to, qty, stockStatus, note)
            if (res.error) setError(res.error)
            else {
                // 【告警不清空表单以外的东西,也不拦任何后续操作】—— 这一次成功了。
                setWarnings(res.warnings ?? [])
                setQty(''); setTo(''); setNote(''); router.refresh()
            }
        })
    }

    return (
        <div className="mt-3 pt-3 border-t">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            {/* IOD-2:琥珀而不是红 —— 货已经搬过去了,红色会让人以为要重搬一次。
                一句一行:两个告警指向两件要分别去做的事。 */}
            {warnings.length > 0 && (
                <div className="bg-amber-50 border border-amber-400 text-amber-900 px-3 py-2 rounded mb-2 space-y-1">
                    {warnings.map((w, i) => (
                        <p key={i} className="text-xs">{w}</p>
                    ))}
                </div>
            )}
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
                {stockStatus === 'on_hold'
                    ? t('stock.transferConsequenceHeld')
                    : stockStatus === 'committed'
                      ? t('stock.transferConsequenceCommitted')
                      : t('stock.transferConsequence')}
            </p>
            {blocked === 'noStock' && <p className="text-xs text-gray-500 mt-1">{t('stock.transferBlockedNoStock')}</p>}
            {blocked === 'noTargets' && <p className="text-xs text-amber-800 mt-1">{t('stock.transferBlockedNoTargets')}</p>}
            {blocked === 'noQty' && <p className="text-xs text-gray-500 mt-1">{t('stock.blockedNoQty')}</p>}
            {blocked === 'noTarget' && <p className="text-xs text-gray-500 mt-1">{t('stock.transferBlockedNoTarget')}</p>}
            {blocked === 'partialCommitted' && (
                <p className="text-xs text-amber-800 mt-1">{t('stock.transferBlockedCommittedPartial', { have: String(have) })}</p>
            )}
        </div>
    )
}
