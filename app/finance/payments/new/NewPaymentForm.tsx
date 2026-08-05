'use client'

// 收付款表单:方向切换(收=客户 / 付=供应商),币种↔银行账户联动(非 USD 出汇率输入),
// 选定往来单位后列出其未结单据逐张核销('fill' 快捷填充 = min(未结, 未冲销余额)),
// 底部实时 USD 款额 / 冲销合计 / 未冲销余额(>0 = 挂账,允许)。提交走 createPayment。
// NOTE: 两侧未结单据全量随 props 下发,此处按往来单位过滤 —— 免一次选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { useActionState, useEffect, useState } from 'react'
import { bankAccountFor, currencyOfBank } from '@/lib/currencyMap'
import Link from 'next/link'
import { createPayment, lookupFxRate, type CreatePaymentState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoney } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: CreatePaymentState = {}

export type PartyOption = { id: string; name: string }

export type OpenItem = {
    doc_id: string // in → sales_record_id / out → inbound_batch_id 或 expense id(按 doc_kind)
    doc_kind: 'sale' | 'inbound' | 'expense'
    party_id: string
    doc_code: string
    doc_date: string
    open_ccy: number
    currency: string
}

// 可预付的采购单(cut 4b):没有"未结额"概念 —— 定金不是在还债,
// 上限(估算总额 × 1.5)由 DB 把守。
export type PoItem = {
    po_id: string
    party_id: string
    code: string
    order_date: string
    estimated_total_usd: number
    prepaid_base: number
    currency: string
}

// 本地日期(YYYY-MM-DD),用作收付日期默认值(避免 UTC 偏移)。
function todayIsoLocal(): string {
    const d = new Date()
    const yyyy = d.getFullYear()
    const mm = String(d.getMonth() + 1).padStart(2, '0')
    const dd = String(d.getDate()).padStart(2, '0')
    return `${yyyy}-${mm}-${dd}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

export default function NewPaymentForm({
    customers,
    suppliers,
    arItems,
    apItems,
    poItems,
    initialDirection,
    initialPartyId = '',
}: {
    customers: PartyOption[]
    suppliers: PartyOption[]
    arItems: OpenItem[]
    apItems: OpenItem[]
    poItems: PoItem[]
    initialDirection: 'in' | 'out'
    initialPartyId?: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createPayment, initialState)

    const [direction, setDirection] = useState<'in' | 'out'>(initialDirection)
    const [partyId, setPartyId] = useState(initialPartyId)
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('USD')
    const [fx, setFx] = useState('')
    const [bank, setBank] = useState('1010') // 初始币种 USD → 1010
    const [alloc, setAlloc] = useState<Record<string, string>>({})
    const [payDate, setPayDate] = useState(todayIsoLocal())
    // 汇率不再由本页计算 —— 向数据库要。null = 还没有结果(未查/查失败)
    const [autoFx, setAutoFx] = useState<number | null>(null)
    const [fxAsOf, setFxAsOf] = useState<string | null>(null)
    const [fxError, setFxError] = useState<string | null>(null)
    const [fxLoading, setFxLoading] = useState(false)

    // 方向切换清空往来单位与核销;换往来单位清空核销
    function onDirectionChange(d: 'in' | 'out') {
        setDirection(d)
        setPartyId('')
        setAlloc({})
    }
    function onPartyChange(id: string) {
        setPartyId(id)
        setAlloc({})
    }
    // 银行账户默认跟随币种(SGD → 1000,USD → 1010),之后仍可手动改
    function onCurrencyChange(c: string) {
        setCurrency(c)
        setBank(bankAccountFor(c))
        setAlloc({})   // 换币种后旧的核销行可能已不同币种,清掉
    }

    // 银行账户的本币(bank_native_currency 的界面侧映射)
    const bankCcy = currencyOfBank(bank) ?? currency
    // 跨币种 = 银行真的换了汇 → 不查牌价,要水单上的实际成交价(record_payment 同规则)
    const crossCurrency = bankCcy !== currency

    // 【任一输入变化都先清空旧汇率】陈旧的汇率绝不能当成当前数字显示
    useEffect(() => {
        setAutoFx(null)
        setFxAsOf(null)
        setFxError(null)
        if (crossCurrency) return          // 这一支用手填的实际成交价,不查牌价
        if (!currency || !payDate) return
        let cancelled = false
        setFxLoading(true)
        lookupFxRate(currency, payDate, direction).then((r) => {
            if (cancelled) return
            setFxLoading(false)
            if (r.error) setFxError(r.error)
            else { setAutoFx(r.rate ?? null); setFxAsOf(r.asOf ?? null) }
        })
        return () => { cancelled = true }
    }, [currency, payDate, direction, crossCurrency])

    const parties = direction === 'in' ? customers : suppliers
    // FIN-2:单据只能用自己的币种结算(服务端 ALLOC_CURRENCY_MISMATCH)。
    // 界面原先不按币种过滤,于是 USD 付款也会把 SGD 的单据列出来给人选 ——
    // 选了必被拒。不提供服务端注定拒绝的选项。
    const items = (direction === 'in' ? arItems : apItems)
        .filter((i) => i.party_id === partyId && i.currency === currency)
    // 付款方向:该供应商可预付的采购单(单独一组,列在 AP 单据之上)
    const pos = direction === 'out'
        ? poItems.filter((p) => p.party_id === partyId && p.currency === currency) : []

    // 【本页不再自己算汇率】跨币种用手填的成交价,其余用数据库返回的牌价。
    // 旧代码写的是 `currency === 'USD' ? 1 : Number(fx)` —— 那是 FIN-0 之前
    // 以 USD 为本位币的残留。FIN-0 之后本位币是 SGD,于是:
    //   * 选 SGD(真本位币)→ 走 else 分支要一个手填汇率,而那个输入框根本不渲染
    //     (它只在跨币种时出现)→ fxValid 恒 false → 基准额算成 0 → 未核销显示 0.00。
    //     这就是走查里看到的 0.00,不是算错,是把有效情形判成了无效。
    //   * 选 USD(其实是外币)→ 拿到 fx = 1,USD 1,000 显示成基准 1,000.00,
    //     而真实约 1,350 —— 这一半更坏:它不报零,它悄悄报了个错的数。
    const amountNum = Number(amount)
    const amountValid = !!amount && !Number.isNaN(amountNum) && amountNum > 0
    const manualFxNum = Number(fx)
    const manualFxValid = !!fx && !Number.isNaN(manualFxNum) && manualFxNum > 0
    const effectiveFx = crossCurrency ? (manualFxValid ? manualFxNum : null) : autoFx
    const payBase = amountValid && effectiveFx !== null ? round2(amountNum * effectiveFx) : null

    const allocValue = (docId: string) => {
        const v = Number(alloc[docId])
        return alloc[docId] && !Number.isNaN(v) && v > 0 ? v : 0
    }
    const totalAllocated = round2(
        items.reduce((s, i) => s + allocValue(i.doc_id), 0) +
            pos.reduce((s, p) => s + allocValue(p.po_id), 0)
    )
    // 【与服务端同币种】record_payment 查的是 v_alloc_total > p_amount,两边都是
    // 【付款币种】。本页原来拿基准额减单据币种的核销额 —— 两种货币相减,
    // 操作员读到的数和服务端校验的数根本不是一回事。
    const unallocated = round2((amountValid ? amountNum : 0) - totalAllocated)

    // fill:该行填到 min(未结额, 未冲销余额[不计本行])
    function fill(item: OpenItem) {
        const others = totalAllocated - allocValue(item.doc_id)
        const remaining = Math.max(0, round2((amountValid ? amountNum : 0) - others))
        const v = Math.min(item.open_ccy, remaining)
        setAlloc((a) => ({ ...a, [item.doc_id]: v > 0 ? String(v) : '' }))
    }
    // 预付行没有单据上限(定金不是在还债)—— fill = 未冲销余额;1.5× 栏杆由 DB 把守
    function fillPo(p: PoItem) {
        const others = totalAllocated - allocValue(p.po_id)
        const remaining = Math.max(0, round2((amountValid ? amountNum : 0) - others))
        setAlloc((a) => ({ ...a, [p.po_id]: remaining > 0 ? String(remaining) : '' }))
    }

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <div className="flex flex-wrap gap-4">
                {/* 方向 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.side')}</label>
                    <select
                        name="direction"
                        value={direction}
                        onChange={(e) => onDirectionChange(e.target.value === 'out' ? 'out' : 'in')}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="in">{t('finance.direction.in')}</option>
                        <option value="out">{t('finance.direction.out')}</option>
                    </select>
                </div>
                {/* 往来单位(必填;收=客户,付=供应商)*/}
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.colCounterparty')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="counterparty_id"
                        required
                        value={partyId}
                        onChange={(e) => onPartyChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('finance.selectCounterparty')}
                        </option>
                        {parties.map((p) => (
                            <option key={p.id} value={p.id}>
                                {p.name}
                            </option>
                        ))}
                    </select>
                </div>
            </div>

            <div className="flex flex-wrap gap-4">
                {/* 金额(必填,原币)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.amount')} <span className="text-red-600">*</span>
                    </label>
                    <DecimalInput
                        name="amount"
                        required
                        value={amount}
                        onChange={setAmount}
                        className="w-36 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 币种 */}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('output.sale.currency')}</label>
                    <select
                        name="currency"
                        value={currency}
                        onChange={(e) => onCurrencyChange(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="USD">USD</option>
                        <option value="SGD">SGD</option>
                    </select>
                </div>
                {/* FIN-0:同币种走外币户按当日牌价自动估值;只有【跨币种】(银行实际
                    做了兑换)才要填 —— 填水单两边实际金额折出的成交价,不是牌价(C4) */}
                {crossCurrency && (
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('finance.actualDealRate')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="fx_rate"
                            required
                            value={fx}
                            onChange={setFx}
                            placeholder={t('finance.actualDealRateHint')}
                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                )}
                {/* 银行账户(默认随币种)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('finance.bankAccount')}</label>
                    <select
                        name="bank_account"
                        value={bank}
                        onChange={(e) => setBank(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="1010">{t('finance.bank.1010')}</option>
                        <option value="1000">{t('finance.bank.1000')}</option>
                    </select>
                </div>
                {/* 收付日期(默认今天)*/}
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('finance.paymentDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="payment_date"
                        required
                        value={payDate}
                        onChange={(e) => setPayDate(e.target.value)}
                        onBlur={(e) => setPayDate(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                {/* 备注 */}
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('finance.memo')}</label>
                    <input
                        type="text"
                        name="notes"
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {/* 预付款(采购单):付款方向、选定供应商后,列其可预付的采购单 ——
                排在 AP 单据之上;alloc_kind 'purchase_order' 由 action 映射为
                purchase_order_id,分录借 1300 而不是 2000 */}
            {partyId && pos.length > 0 && (
                <div>
                    <h3 className="text-sm font-bold text-gray-700 mb-2">
                        {t('purchasing.prepaymentGroup')}
                    </h3>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDocument')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colOrderDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colEstimatedTotal')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colPrepaid')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAllocate')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {pos.map((p) => (
                                <tr key={p.po_id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{p.code}</td>
                                    <td className="border border-gray-300 px-4 py-2">{p.order_date}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatMoney(p.estimated_total_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatMoney(p.prepaid_base)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="alloc_id" value={p.po_id} />
                                        <input type="hidden" name="alloc_kind" value="purchase_order" />
                                        <DecimalInput
                                            name="alloc_amount"
                                            value={alloc[p.po_id] ?? ''}
                                            onChange={(raw) =>
                                                setAlloc((a) => ({ ...a, [p.po_id]: raw }))
                                            }
                                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                                        />
                                        <button
                                            type="button"
                                            onClick={() => fillPo(p)}
                                            className="ml-2 text-blue-600 hover:underline text-sm"
                                        >
                                            {t('finance.fillAll')}
                                        </button>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                    <p className="text-xs text-gray-500 mt-1">{t('purchasing.prepaymentNote')}</p>
                </div>
            )}

            {/* 核销:选定往来单位后列其未结单据 */}
            {partyId && (
                items.length > 0 ? (
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDocument')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAllocate')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {items.map((i) => (
                                <tr key={i.doc_id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {i.doc_code}
                                        {/* AP 侧标注单据类别(进料/开支),看清核销对象;AR 全是销售,不标 */}
                                        {i.doc_kind !== 'sale' && (
                                            <span className="ml-2 px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-500 font-sans">
                                                {t('finance.docKind.' + i.doc_kind)}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">{i.doc_date}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatMoney(i.open_ccy)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="alloc_id" value={i.doc_id} />
                                        <input type="hidden" name="alloc_kind" value={i.doc_kind} />
                                        {/* 上限不再由 max 属性约束(text 输入无此语义);
                                            超额由 DB 的 ALLOC_EXCEEDS 拦下,口径不变 */}
                                        <DecimalInput
                                            name="alloc_amount"
                                            value={alloc[i.doc_id] ?? ''}
                                            onChange={(raw) =>
                                                setAlloc((a) => ({ ...a, [i.doc_id]: raw }))
                                            }
                                            className="w-32 border border-gray-300 px-3 py-2 rounded"
                                        />
                                        <button
                                            type="button"
                                            onClick={() => fill(i)}
                                            className="ml-2 text-blue-600 hover:underline text-sm"
                                        >
                                            {t('finance.fillAll')}
                                        </button>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                ) : (
                    <p className="text-sm text-gray-500">{t('finance.noOpenItems')}</p>
                )
            )}

            {/* 缺牌价就【拒绝】—— 不回退 0、不回退 1。日期/币种/取哪一侧都说清楚 */}
            {fxError && (
                <div className="rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {fxError}
                </div>
            )}

            {/* 实时合计:付款币种金额 / 折算基准额 / 冲销合计 / 未冲销 */}
            <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm items-center">
                <div>
                    {/* 【不能用 finance.colAmount】那个键写死了"(SGD)",而这里显示的是
                        【付款币种】的金额 —— 标签说 SGD、数字后面跟着 USD,自相矛盾 */}
                    <span className="text-gray-600 mr-1">{t('finance.paymentAmount')}:</span>
                    <span className="font-mono font-medium">
                        {formatMoney(amountValid ? amountNum : 0)} {currency}
                    </span>
                </div>
                {/* 基准额单列一格,并标明是折算值 —— 与上面的付款币种金额不再混为一谈 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.baseEquivalent')}:</span>
                    <span className="font-mono">
                        {payBase === null ? '—' : formatMoney(payBase)}
                        {effectiveFx !== null && (
                            <span className="ml-1 text-xs text-gray-500">
                                @ {effectiveFx}
                                {/* 取自哪一天:与交易日不同时【必须说出来】 */}
                                {!crossCurrency && fxAsOf && fxAsOf !== payDate
                                    && ' ' + t('finance.fxLookup.asOf', { 0: fxAsOf })}
                                {crossCurrency && ' ' + t('finance.fxLookup.dealt')}
                            </span>
                        )}
                    </span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalAllocated')}:</span>
                    <span className="font-mono font-medium">{formatMoney(totalAllocated)} {currency}</span>
                </div>
                <div className={unallocated < 0 ? 'text-red-600' : 'text-gray-500'}>
                    <span className="mr-1">{t('finance.unallocated')}:</span>
                    <span className="font-mono">{formatMoney(unallocated)} {currency}</span>
                    {unallocated < 0 && (
                        <span className="ml-2 text-xs">{t('finance.overAllocated')}</span>
                    )}
                </div>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending || fxLoading || effectiveFx === null || unallocated < 0}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('finance.submitPayment')}
                </button>
                <Link
                    href="/finance/payments"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
