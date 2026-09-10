'use client'

// 计价面板:当前 USD 单价(只读)+ 设价表单(价格/币种/汇率/备注)+ 价格历史。
// 走 set_inbound_unit_price RPC —— 每次变更都有 price_history 审计行。
import { useActionState, useEffect, useState } from 'react'
import { setInboundPrice, type SetPriceState } from './pricingActions'
import { useTranslations } from '@/lib/i18n/client'
import { formatUnitCost } from '@/lib/format'
import { MaskedValue } from '@/app/components/MaskedValue'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

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

    // ════════════════════════════════════════════════════════════════════
    // TABLE-CONVERT-5 · 价格历史表 —— ★ 这张表此前【没有】手机档判断 ★
    // ════════════════════════════════════════════════════════════════════
    // 转换前一处 hidden sm:table-cell 都没有,五列在 390px 上靠外层
    // overflow-x-auto 横着拖(TABLE-MEASURE-1 实测 +35px,露一半的是 Notes)。
    // ☞ 所以下面这三列是【新判断】,不是搬运。
    //
    // ★【留哪三列 —— 时间 · 旧价 · 新价。而"三"这个数字要给理由】
    //   身份是【时间】:一条价格历史行就是"某一刻发生的一次改价",除了时间没有别的
    //   东西能认出它(同一批次可以在同一天改两次价)。
    //   而这张表存在的理由是【那次改动本身】—— 而一次改动是【一个位移】,
    //   位移要两个端点才成立。只留"新价"会把一张历史表变成一列孤零零的数字:
    //   人还是不知道它是涨了还是跌了。**所以结论这一栏占两列,这是说出来的例外。**
    //
    // ★【录入原值 / 备注 为什么折】
    //   「录入原值」是出处(原币 + 牌价 + 取自哪一天),FIN-21 要求它跟着数字走 ——
    //   它【跟着走进了展开区】,带着自己的列头,一点就到。
    //   「备注」本来就是补充说明,而读数说 390px 上露一半的正好就是它(TM-1 §6:⑤)。
    const columns: Column<PriceHistoryRow>[] = [
        {
            key: 'when',
            header: t('inbound.pricing.colWhen'),
            // ★ 身份 —— 手机上留下。
            priority: true,
            render: (h) => h.created_at_display,
        },
        {
            key: 'old',
            header: t('inbound.pricing.colOld'),
            // ★ 位移的起点 —— 手机上留下。
            priority: true,
            className: 'font-mono',
            render: (h) => (
                <MaskedValue
                    value={h.old_unit_price}
                    canView={canViewPrices}
                    format={formatUnitCost}
                    fallback="—"
                />
            ),
        },
        {
            key: 'new',
            header: t('inbound.pricing.colNew'),
            // ★ 位移的终点,也就是此后生效的那个价 —— 手机上留下。
            priority: true,
            className: 'font-mono',
            render: (h) => (
                <MaskedValue value={h.new_unit_price} canView={canViewPrices} format={formatUnitCost} />
            ),
        },
        {
            key: 'original',
            header: t('inbound.pricing.colOriginal'),
            className: 'font-mono',
            render: (h) => (
                <>
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
                </>
            ),
        },
        {
            key: 'notes',
            header: t('inbound.pricing.colNotes'),
            render: (h) => h.notes ?? '—',
        },
    ]

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
            {/* TABLE-CONVERT-5:空态搬进了 DataTable 的 empty prop(同一个
                inbound.pricing.historyEmpty),旧那一支不留 —— 见 TABLE-CONVERT-3 §6.1。 */}
            <DataTable
                rows={history}
                columns={columns}
                rowKey={(h) => h.id}
                phone={{ mode: 'columns' }}
                empty={t('inbound.pricing.historyEmpty')}
            />
        </section>
    )
}
