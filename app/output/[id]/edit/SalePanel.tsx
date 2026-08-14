'use client'

// 销售登记面板。仅在批次未软删且 remaining_qty > 0 时由页面渲染。
// cut 1:销售必须带价 —— 单价 + 币种(非 USD 附汇率)+ 可选客户,实时金额预览。
// 成功后服务端 revalidate 重取,remaining/state/时间线一起刷新;表单用 formKey 清空。
import { useActionState, useEffect, useState } from 'react'
import { recordSale, quoteSalePrice, type SaleState, type QuoteState } from './saleActions'
import { STATE_OPTIONS, labelKeyForValue } from '../../../inbound/options'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare, formatAmount } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: SaleState = {}

type CustomerOption = { id: string; code: string; legal_name: string }

function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

// SAL-B6:客户信用状况(customer_credit_status 的一行)
export type CreditRow = {
    customer_id: string
    code: string
    credit_limit_base: number | null
    credit_hold: boolean
    exposure_base: number | null
    headroom_base: number | null
    sales_blocked: boolean
}

export default function SalePanel({
    canSeeCredit,
    credit,
    batchId,
    remainingQty,
    availableQty,
    heldQty,
    committedQty,
    unit,
    state,
    customers,
    batchCustomerId,
    baseCurrency,
    formulas,
}: {
    // 【无权时拿不到行,而不是拿到 0】—— 面板据此渲染「受限」
    canSeeCredit: boolean
    credit: CreditRow[]
    batchId: string
    remainingQty: number
    // IOD-1:【可卖的是可用,不是物理剩余】。两个数一起摆出来,否则人看着
    // remaining 够却卖不掉,屏幕上没有任何东西解释为什么。
    availableQty: number
    heldQty: number
    // SO-2:第三个"货在那里但你动不了"的桶。与暂扣并列而不是合并 ——
    // 两者不能动的【理由】不同,合成一个数就等于让人去猜是哪一个。
    committedQty: number
    unit: string
    state: string
    customers: CustomerOption[]
    batchCustomerId: string | null
    baseCurrency: string
    /** SAL-A:方向为 sale/both 的启用公式(读自 pricing_formulas_masked;无 pricing
     *  权限时为空数组 → 只剩手填与现货预设) */
    formulas: { id: string; code: string; name: string }[]
}) {
    const t = useTranslations()
    const recordWithId = recordSale.bind(null, batchId)
    const [st, formAction, isPending] = useActionState(recordWithId, initialState)
    const [formKey, setFormKey] = useState(0)

    // 金额预览要读输入值 → 受控;成功后连同 formKey 一起复位
    const [quantity, setQuantity] = useState('')
    const [customerId, setCustomerId] = useState(batchCustomerId ?? '')

    // SAL-B6:选中客户的信用状况 —— 在【录入之前】说,而不是等提交被拒才说
    // (与收货表单同一条规矩:理由长在控件旁边)。
    const creditRow = customerId ? credit.find((c) => c.customer_id === customerId) ?? null : null
    // 有客户、有权限却没有行 = 那个客户被软删了;有客户、无权限 = 受限
    const creditRestricted = customerId !== '' && !canSeeCredit
    // 服务端【保证会拒】的两种:冻结,或敞口已经够到限额。其余情形不禁钮 ——
    // "这一单会不会顶过线"取决于金额与汇率,那是提交时才知道的事,面板给余额让人自己判断。
    const creditBlocked = creditRow?.sales_blocked === true
    const [unitPrice, setUnitPrice] = useState('')
    const [currency, setCurrency] = useState('USD')
    // SAL-A:三种模型 —— manual 手填 / formula 公式 / spot 现货预设(退化公式,
    // 由 DB 侧填 terms 走同一台引擎,不是第四条分支)。computed 的价带出处;
    // 【报价之后手改价格 → 出处退回 manual 并丢弃依据】:改过的数字挂着"算出来的"
    // 依据,正是 FIN-26 修掉的那种误读。
    const [priceMode, setPriceMode] = useState<'manual' | 'formula' | 'spot'>('manual')
    const [quoteFormulaId, setQuoteFormulaId] = useState('')
    const [quote, setQuote] = useState<QuoteState | null>(null)
    const [quoting, setQuoting] = useState(false)
    const computed = quote?.unitPrice !== undefined && unitPrice === String(quote.unitPrice)

    // 成功后清空录入(重挂表单 + 复位受控值)
    useEffect(() => {
        if (st.success) {
            setFormKey((k) => k + 1)
            setQuantity('')
            setUnitPrice('')
            setCurrency('USD')
            setQuote(null)
            setPriceMode('manual')
        }
    }, [st.success])

    const stateLabel = (v: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, v)
        return key ? t(key) : v
    }

    // 实时预览:qty × price = 原币金额;SGD 折算由 DB 按当日牌价定,预览不猜数
    const qtyN = Number(quantity)
    const priceN = Number(unitPrice)
    const previewValid =
        quantity !== '' && unitPrice !== '' && !Number.isNaN(qtyN) && !Number.isNaN(priceN) &&
        qtyN > 0 && priceN > 0
    const previewAmount = previewValid ? Math.round(qtyN * priceN * 100) / 100 : null

    return (
        <section className="mt-8 pt-8 border-t">
            <h2 className="text-xl font-bold mb-4">{t('output.sale.title')}</h2>

            <div className="bg-gray-50 rounded p-4 mb-4 flex flex-wrap gap-8 text-sm">
                <div>
                    <span className="text-gray-600 mr-1">{t('output.sale.remainingLabel')}:</span>
                    <span className="font-medium font-mono">{remainingQty} {unit}</span>
                </div>
                {/* IOD-1:可售与暂扣分开列。remaining 留着 —— 它回答的是
                    "这批货还剩多少",而可售回答的是"我现在能卖多少",
                    两个问题在有暂扣时答案不同,合成一个数就等于把差额藏起来。 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('stock.saleAvailable')}:</span>
                    <span className="font-medium font-mono">{availableQty} {unit}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('stock.saleHeld')}:</span>
                    <span className={'font-medium font-mono ' + (heldQty > 0 ? 'text-amber-800' : '')}>
                        {heldQty} {unit}
                    </span>
                </div>
                {/* SO-2:已承诺 —— 点名它是"许给了订单",并把人送到订单那一侧去
                    (释放在那里,不在这个页面上:撤回一个承诺是销售的动作)。 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('stock.saleCommitted')}:</span>
                    <span className={'font-medium font-mono ' + (committedQty > 0 ? 'text-blue-800' : '')}>
                        {committedQty} {unit}
                    </span>
                    {committedQty > 0 && (
                        <span className="text-xs text-gray-500 ml-2">{t('stock.saleCommittedHint')}</span>
                    )}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('output.sale.stateLabel')}:</span>
                    <span className="px-2 py-0.5 bg-gray-200 rounded text-xs">{stateLabel(state)}</span>
                </div>
            </div>

            {st.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4">
                    {st.error}
                </div>
            )}

            <form key={formKey} action={formAction} className="space-y-3">
                {/* SAL-A:定价 —— Doc 1 点名的痛("不同定价模型整合进本模块")。
                    现货是【预设】(DB 侧填 100%/0/0 的 terms 走同一台引擎);
                    换算在 DB 里按 tt_buy(收钱进来)—— 不是买路径的 tt_sell。 */}
                <div className="flex flex-wrap gap-2 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.pricing.mode')}</label>
                        <select
                            value={priceMode}
                            onChange={(e) => { setPriceMode(e.target.value as 'manual' | 'formula' | 'spot'); setQuote(null) }}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="manual">{t('output.sale.pricing.manual')}</option>
                            <option value="spot">{t('output.sale.pricing.spot')}</option>
                            <option value="formula">{t('output.sale.pricing.formula')}</option>
                        </select>
                    </div>
                    {priceMode === 'formula' && (
                        <div>
                            <label className="block text-sm font-medium mb-1">{t('output.sale.pricing.formulaPick')}</label>
                            <select
                                value={quoteFormulaId}
                                onChange={(e) => setQuoteFormulaId(e.target.value)}
                                className="border border-gray-300 px-3 py-2 rounded"
                            >
                                <option value="">—</option>
                                {formulas.map((f) => (
                                    <option key={f.id} value={f.id}>{f.code} · {f.name}</option>
                                ))}
                            </select>
                        </div>
                    )}
                    {priceMode !== 'manual' && (
                        <button
                            type="button"
                            disabled={quoting}
                            onClick={() => {
                                const fd = new FormData()
                                fd.set('quote_formula_id', priceMode === 'formula' ? quoteFormulaId : '')
                                fd.set('currency', currency)
                                fd.set('quantity', quantity)
                                fd.set('sale_date', (document.querySelector('input[name=sale_date]') as HTMLInputElement)?.value ?? '')
                                setQuoting(true)
                                quoteSalePrice(batchId, fd).then((q) => {
                                    setQuoting(false)
                                    setQuote(q)
                                    if (q.unitPrice !== undefined) setUnitPrice(String(q.unitPrice))
                                })
                            }}
                            className="bg-gray-800 text-white text-sm px-3 py-2 rounded hover:bg-gray-700 disabled:bg-gray-400"
                        >
                            {quoting ? t('output.sale.pricing.quoting') : t('output.sale.pricing.quote')}
                        </button>
                    )}
                </div>
                {quote?.error && <p className="text-red-600 text-sm">{quote.error}</p>}
                {quote?.summary && (
                    <p className="text-xs text-gray-600">
                        {t('output.sale.pricing.quoted', {
                            usd: String(quote.summary.usdPerKg),
                            factor: quote.summary.fxFactor.toFixed(4),
                            side: quote.summary.fxSide,
                            series: quote.summary.series,
                        })}
                    </p>
                )}
                {/* 出处随行:computed 只有在【价格没被手改】时成立 */}
                <input type="hidden" name="price_source" value={computed ? 'computed' : 'manual'} />
                <input type="hidden" name="price_provenance" value={computed && quote?.provenance ? JSON.stringify(quote.provenance) : ''} />
                <div className="flex flex-wrap gap-2 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('output.sale.quantity')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="quantity"
                            required
                            value={quantity}
                            onChange={setQuantity}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('output.sale.unitPrice')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="unit_price"
                            required
                            value={unitPrice}
                            onChange={setUnitPrice}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.currency')}</label>
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
                    {/* FIN-0:外币按销售日行方买入价(tt_buy)自动估值,当天没牌价直接拒 */}
                    {currency !== baseCurrency && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                </div>

                <div className="flex flex-wrap gap-2 items-end">
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.customer')}</label>
                        <select
                            name="customer_id"
                            value={customerId}
                            onChange={(e) => setCustomerId(e.target.value)}
                            className="border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="">{t('output.form.selectCustomerOptional')}</option>
                            {customers.map((c) => (
                                <option key={c.id} value={c.id}>
                                    {c.code} - {c.legal_name}
                                </option>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">{t('output.sale.saleDate')}</label>
                        <input
                            type="date"
                            name="sale_date"
                            required
                            defaultValue={todayIsoLocal()}
                            className="border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div className="flex-1 min-w-[8rem]">
                        <label className="block text-sm font-medium mb-1">{t('output.sale.notes')}</label>
                        <input
                            type="text"
                            name="notes"
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <button
                        type="submit"
                        disabled={isPending || creditBlocked}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                    >
                        {t('output.sale.button')}
                    </button>
                </div>
                {/* ── SAL-B6:信用状况,在录入之前 ────────────────────────────
                    SAL-B 建了管控却没有任何一块屏把限额与敞口放在一起,于是唯一
                    会说话的是被拒的那一刻。这里在选中客户之后就说,并且【只在
                    服务端保证会拒时】禁钮(冻结、或敞口已够到限额)—— 其余情形
                    给余额,让人自己判断,不假装算得出这一单会不会顶过线。 */}
                {creditRestricted && (
                    <p className="mt-3 text-sm text-gray-500">{t('output.sale.credit.restricted')}</p>
                )}
                {creditRow?.credit_hold && (
                    <p className="mt-3 bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded text-sm">
                        {t('output.sale.credit.hold', { customer: creditRow.code })}
                    </p>
                )}
                {!creditRow?.credit_hold && creditRow?.credit_limit_base !== null && creditRow !== null && (
                    <p className={'mt-3 px-4 py-3 rounded text-sm border ' + (creditRow.sales_blocked
                        ? 'bg-red-100 border-red-400 text-red-700'
                        : 'bg-gray-50 border-gray-300 text-gray-700')}>
                        {creditRow.sales_blocked
                            ? t('output.sale.credit.over', {
                                  customer: creditRow.code,
                                  limit: formatAmount(creditRow.credit_limit_base, baseCurrency),
                                  exposure: formatAmount(creditRow.exposure_base, baseCurrency),
                              })
                            : t('output.sale.credit.room', {
                                  limit: formatAmount(creditRow.credit_limit_base, baseCurrency),
                                  exposure: formatAmount(creditRow.exposure_base, baseCurrency),
                                  headroom: formatAmount(creditRow.headroom_base, baseCurrency),
                              })}
                    </p>
                )}

                {/* SAL-C:不选客户是【正当的】(客户还没登记就卖了货)—— 所以这是
                    一条说明,不是守卫:【绝不禁用提交】。但后果要在按下之前说清楚,
                    与收货表单同一条规矩:理由长在控件旁边,而不是点下去之后才出现。
                    走查那 1,397 就是这么溜过信用管控的:表单只写了"(可选)",
                    没说"可选的代价是这笔钱不算进任何人的敞口"。 */}
                {!customerId && (
                    <p className="mt-3 bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded text-sm">
                        {t('output.sale.noCustomerNotice')}
                    </p>
                )}

                {previewAmount !== null && (
                    <p className="text-sm text-gray-600">
                        {t('output.sale.amountPreview', {
                            amount: formatMoneyBare(previewAmount, '同句 output.sale.amountPreview 里紧跟其后的 {ccy}'),
                            ccy: currency,
                        })}
                    </p>
                )}
            </form>
        </section>
    )
}
