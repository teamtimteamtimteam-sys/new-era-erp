'use client'

// 计价面板:当前 USD 单价(只读)+ 设价表单(价格/币种/汇率/备注)+ 价格历史。
// 走 set_inbound_unit_price RPC —— 每次变更都有 price_history 审计行。
import { useActionState, useEffect, useState } from 'react'
import { setInboundPrice, type SetPriceState } from './pricingActions'
import { useTranslations } from '@/lib/i18n/client'
import { formatUnitCost } from '@/lib/format'

const initialState: SetPriceState = {}

export type PriceHistoryRow = {
    id: string
    old_unit_price: number | null
    new_unit_price: number
    currency: string
    original_price: number
    fx_rate: number
    notes: string | null
    created_at_display: string // 服务端预格式化,避免水合不一致
}

export default function PricingPanel({
    batchId,
    unitPrice,
    history,
}: {
    batchId: string
    unitPrice: number | null
    history: PriceHistoryRow[]
}) {
    const t = useTranslations()
    const setWithId = setInboundPrice.bind(null, batchId)
    const [st, formAction, isPending] = useActionState(setWithId, initialState)
    const [formKey, setFormKey] = useState(0)
    const [currency, setCurrency] = useState('USD')

    // 成功后清空录入(重挂表单)
    useEffect(() => {
        if (st.success) {
            setFormKey((k) => k + 1)
            setCurrency('USD')
        }
    }, [st.success])

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('inbound.pricing.title')}</h2>

            <div className="bg-gray-50 rounded p-4 mb-4 text-sm">
                <span className="text-gray-600 mr-1">{t('inbound.pricing.current')}:</span>
                {unitPrice !== null ? (
                    <span className="font-medium font-mono">{formatUnitCost(unitPrice)}</span>
                ) : (
                    <span className="text-gray-400">{t('inbound.pricing.notSet')}</span>
                )}
            </div>

            {st.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {st.error}
                </div>
            )}

            <form key={formKey} action={formAction} className="flex flex-wrap gap-2 items-end mb-6">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('inbound.pricing.price')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="number"
                        name="price"
                        step="any"
                        min="0"
                        required
                        className="w-32 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('inbound.pricing.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => setCurrency(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="USD">USD</option>
                        <option value="SGD">SGD</option>
                    </select>
                </div>
                {currency !== 'USD' && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('inbound.pricing.fxRate')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="number"
                            name="fx_rate"
                            step="any"
                            min="0"
                            required
                            placeholder={t('inbound.pricing.fxHint')}
                            className="w-36 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
                <div className="flex-1 min-w-[8rem]">
                    <label className="block text-sm font-medium mb-1">{t('inbound.pricing.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('inbound.pricing.submit')}
                </button>
            </form>

            <h3 className="text-sm font-semibold mb-2">{t('inbound.pricing.historyTitle')}</h3>
            {history.length === 0 ? (
                <p className="text-sm text-gray-500">{t('inbound.pricing.historyEmpty')}</p>
            ) : (
                <div className="overflow-x-auto">
                    <table className="w-full border-collapse border border-gray-300 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('inbound.pricing.colWhen')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('inbound.pricing.colOld')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('inbound.pricing.colNew')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('inbound.pricing.colOriginal')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('inbound.pricing.colNotes')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {history.map((h) => (
                                <tr key={h.id}>
                                    <td className="border border-gray-300 px-3 py-2">{h.created_at_display}</td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        {h.old_unit_price !== null ? formatUnitCost(h.old_unit_price) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        {formatUnitCost(h.new_unit_price)}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        {h.original_price} {h.currency}
                                        {h.currency !== 'USD' ? ` @ ${h.fx_rate}` : ''}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">{h.notes ?? '—'}</td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </section>
    )
}
