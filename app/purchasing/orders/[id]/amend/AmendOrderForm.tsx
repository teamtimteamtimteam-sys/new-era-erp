'use client'

// PUR-2:修改采购单的表单。
//
// 【本表单不自己判断能不能改】守卫在触发器上,拒绝由 DB 点名。这里做的只有两件事:
//   * 把【已收多少】写在行上 —— 下限要在动手之前看得见,而不是保存之后才被拒(CMP-2);
//   * 理由必填 —— 一次改动没有理由,历史上就只是一行"数字变了"。
// 真正的把关仍在 DB:表单上的提示是【礼貌】,不是保护。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { amendOrder, type AmendState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { Button } from '@/app/components/ui/button'

export type AmendLine = {
    id: string
    line_no: number
    quantity: number
    unit: string
    estimated_unit_price: number | null
    received: number
}

const initialState: AmendState = {}

export default function AmendOrderForm({
    poId, code, status, currency, orderDate, expectedDelivery, incoterm, notes, lines,
}: {
    poId: string; code: string; status: string; currency: string
    orderDate: string; expectedDelivery: string; incoterm: string; notes: string
    lines: AmendLine[]
}) {
    const t = useTranslations()
    const amendWithId = amendOrder.bind(null, poId)
    const [state, formAction, isPending] = useActionState(amendWithId, initialState)
    const [qty, setQty] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, String(l.quantity)])))
    const [price, setPrice] = useState<Record<string, string>>(
        () => Object.fromEntries(lines.map((l) => [l.id, l.estimated_unit_price === null ? '' : String(l.estimated_unit_price)])))
    const [remove, setRemove] = useState<Record<string, boolean>>({})

    // 已结束/已作废的单不能改 —— 服务端会拒,页面不摆一个注定失败的按钮
    const frozen = status === 'closed' || status === 'cancelled'

    return (
        <div className="max-w-4xl">
            <div className="mb-6">
                <Link href={`/purchasing/orders/${poId}`} className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>
            <h1 className="text-2xl font-bold mb-2">{t('purchasing.amend.title', { code })}</h1>
            <p className="text-sm text-gray-600 mb-6 max-w-3xl">{t('purchasing.amend.intro')}</p>

            {frozen && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4">
                    {t('purchasing.amend.frozen', { status: t('purchasing.status.' + status) })}
                </div>
            )}
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {state.error}
                </div>
            )}

            <form action={formAction} className="space-y-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.amend.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" name="reason" required disabled={frozen}
                        className="w-full border border-gray-300 px-3 py-2 rounded" />
                    <p className="text-xs text-gray-500 mt-1">{t('purchasing.amend.reasonHint')}</p>
                </div>

                <div className="flex flex-wrap gap-4">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.orderDate')}</label>
                        <input type="date" name="order_date" defaultValue={orderDate} disabled={frozen}
                            className="border border-gray-300 px-3 py-2 rounded" />
                        {/* 改单据日会重取牌价 —— 缺牌价即拒,绝不编一个 */}
                        <p className="text-xs text-gray-500 mt-1">{t('purchasing.amend.orderDateHint')}</p>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.expected')}</label>
                        <input type="date" name="expected_delivery_date" defaultValue={expectedDelivery}
                            disabled={frozen} className="border border-gray-300 px-3 py-2 rounded" />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('purchasing.amend.incoterm')}</label>
                        <input type="text" name="incoterm" defaultValue={incoterm} disabled={frozen}
                            className="border border-gray-300 px-3 py-2 rounded" />
                    </div>
                </div>

                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">#</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.amend.colQty')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.amend.colReceived')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.amend.colPrice', { ccy: currency })}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.amend.colRemove')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {lines.map((l) => {
                            const below = Number(qty[l.id] || 0) < l.received && !remove[l.id]
                            return (
                                <tr key={l.id} className={remove[l.id] ? 'bg-gray-100 text-gray-400' : ''}>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {l.line_no}
                                        <input type="hidden" name="line_id" value={l.id} />
                                        <input type="hidden" name="line_remove" value={remove[l.id] ? '1' : '0'} />
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right">
                                        <DecimalInput name="line_quantity" value={qty[l.id] ?? ''}
                                            onChange={(raw) => setQty((q) => ({ ...q, [l.id]: raw }))}
                                            disabled={frozen || remove[l.id]}
                                            className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                        {/* 下限写在行上 —— 保存之后才被拒是最差的一种告知 */}
                                        {below && (
                                            <p className="text-xs text-red-600 mt-1">
                                                {t('purchasing.amend.belowReceived', { received: l.received })}
                                            </p>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm text-gray-600">
                                        {l.received} {l.unit}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right">
                                        <DecimalInput name="line_price" value={price[l.id] ?? ''}
                                            onChange={(raw) => setPrice((p) => ({ ...p, [l.id]: raw }))}
                                            disabled={frozen || remove[l.id]}
                                            className="w-28 border border-gray-300 px-2 py-1 rounded text-right" />
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <label className="text-sm">
                                            <input type="checkbox" checked={!!remove[l.id]} disabled={frozen || l.received > 0}
                                                onChange={(e) => setRemove((r) => ({ ...r, [l.id]: e.target.checked }))} />
                                            {/* 收过货的行删不掉 —— 复选框直接禁用并说明 */}
                                            <span className="ml-1">
                                                {l.received > 0 ? t('purchasing.amend.cannotRemove') : t('purchasing.amend.remove')}
                                            </span>
                                        </label>
                                    </td>
                                </tr>
                            )
                        })}
                    </tbody>
                </table>

                <div>
                    <label className="block text-sm font-medium mb-1">{t('purchasing.amend.notes')}</label>
                    <textarea name="notes" rows={2} defaultValue={notes} disabled={frozen}
                        className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>

                <div className="flex gap-3 pt-2">
                    <Button type="submit" disabled={isPending || frozen}>
                        {isPending ? t('common.saving') : t('purchasing.amend.submit')}
                    </Button>
                    <Link href={`/purchasing/orders/${poId}`}
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                        {t('common.cancel')}
                    </Link>
                </div>
            </form>
        </div>
    )
}
