'use client'

// 计价面板:当前 USD 单价(只读)+ 设价表单(价格/币种/汇率/备注)+ 价格历史。
// 走 set_inbound_unit_price RPC —— 每次变更都有 price_history 审计行。
import { useActionState, useEffect, useState } from 'react'
import { setInboundPrice, type SetPriceState } from './pricingActions'
import { useTranslations } from '@/lib/i18n/client'
import { formatUnitCost } from '@/lib/format'
import { MaskedValue } from '@/app/components/MaskedValue'
import { Button } from '@/app/components/ui/button'

const initialState: SetPriceState = {}

export type PriceHistoryRow = {
    id: string
    // cut 2b:没有 data.view_prices 时,遮蔽视图把这四列返回 null,界面显示「受限」。
    // old_unit_price 本来就可空(首次定价没有旧价)—— 两种 null 靠 canViewPrices 区分。
    old_unit_price: number | null
    new_unit_price: number | null
    currency: string
    original_price: number | null
    fx_rate: number | null
    // FIN-21:所用牌价取自哪一天、哪一侧;旧行(FIN-21 前)为 null,留白不补造
    rate_as_of: string | null
    rate_type: string | null
    priced_date: string | null   // 定价日(SG 日历),as-of 与它不同才标出来
    notes: string | null
    created_at_display: string // 服务端预格式化,避免水合不一致
}

export default function PricingPanel({
    batchId,
    unitPrice,
    history,
    canViewPrices,
    extraAction,
    baseCurrency,
}: {
    batchId: string
    unitPrice: number | null
    history: PriceHistoryRow[]
    /** cut 2b:当前登录者是否持有 data.view_prices。为 false 时价格显示「受限」。 */
    canViewPrices: boolean
    // cut 5b:批次有定价公式时,页面在这里塞进"按当前含量重新计价"
    extraAction?: React.ReactNode
    baseCurrency: string
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
                {/* cut 2b:null 有两种含义 —— 没有 data.view_prices 时是「受限」,
                    有权限而仍为 null 才是真的「未定价」。两者绝不能混为一谈。 */}
                {!canViewPrices && unitPrice === null ? (
                    <MaskedValue value={null} canView={false} />
                ) : unitPrice !== null ? (
                    <span className="font-medium font-mono">{formatUnitCost(unitPrice)}</span>
                ) : (
                    <span className="text-gray-400">{t('inbound.pricing.notSet')}</span>
                )}
            </div>

            {extraAction}

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
                {/* FIN-0:外币按定价日行方卖出价(tt_sell)自动估值,当天没牌价直接拒 */}
                {currency !== baseCurrency && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                <div className="flex-1 min-w-[8rem]">
                    <label className="block text-sm font-medium mb-1">{t('inbound.pricing.notes')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <Button
                    type="submit"
                    disabled={isPending}
                >
                    {isPending ? t('common.saving') : t('inbound.pricing.submit')}
                </Button>
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
                                        <MaskedValue value={h.old_unit_price} canView={canViewPrices} format={formatUnitCost} fallback="—" />
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <MaskedValue value={h.new_unit_price} canView={canViewPrices} format={formatUnitCost} />
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono">
                                        <MaskedValue value={h.original_price} canView={canViewPrices} />{' '}
                                        {h.original_price !== null ? h.currency : ''}
                                        {/* FIN-21:汇率必须带上侧与(回溯时)取自哪一天 ——
                                            "4.24 USD @ 1.22" 是个查不回去的数;
                                            "@ 1.22 tt_sell" + as-of 标记才是。旧行没记,留白。 */}
                                        {h.currency !== baseCurrency && h.fx_rate !== null ? ` @ ${h.fx_rate}` : ''}
                                        {h.currency !== baseCurrency && h.fx_rate !== null && h.rate_type && (
                                            <span className="ml-1 text-xs text-gray-500">{h.rate_type}</span>
                                        )}
                                        {h.currency !== baseCurrency && h.rate_as_of && h.priced_date && h.rate_as_of !== h.priced_date && (
                                            <span className="ml-1 px-1 rounded bg-amber-100 text-amber-800 text-xs font-sans">
                                                {t('finance.fxLookup.asOf', { 0: h.rate_as_of })}
                                            </span>
                                        )}
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
