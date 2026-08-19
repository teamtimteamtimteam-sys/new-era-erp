'use client'

import { CounterpartyOptions, parseCounterparty, counterpartyValue } from '@/app/components/finance/counterpartyOptions'
// 收付款表单:方向切换(收=客户 / 付=供应商),币种↔银行账户联动(非 USD 出汇率输入),
// 选定往来单位后列出其未结单据逐张核销('fill' 快捷填充 = min(未结, 未冲销余额)),
// 底部实时 USD 款额 / 冲销合计 / 未冲销余额(>0 = 挂账,允许)。提交走 createPayment。
// NOTE: 两侧未结单据全量随 props 下发,此处按往来单位过滤 —— 免一次选择后的往返;
// 数据量小(未结清才进视图),体量上来再改按需加载。
import { useActionState, useEffect, useState } from 'react'
import { bankAccountFor, currencyOfBank } from '@/lib/currencyMap'
import Link from 'next/link'
import { createPayment, lookupFxRate, lookupRatesFor, type CreatePaymentState } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'

const initialState: CreatePaymentState = {}

export type PartyOption = { id: string; name: string }

export type OpenItem = {
    doc_id: string // in → sales_record_id 或 invoice_id / out → inbound_batch_id 或 expense id(按 doc_kind)
    doc_kind: 'sale' | 'invoice' | 'inbound' | 'expense'
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
    estimated_total_ccy: number
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
    employees,
    arItems,
    apItems,
    poItems,
    initialDirection,
    initialPartyId = '',
    baseCurrency,
}: {
    customers: PartyOption[]
    suppliers: PartyOption[]
    employees: PartyOption[]
    arItems: OpenItem[]
    apItems: OpenItem[]
    poItems: PoItem[]
    initialDirection: 'in' | 'out'
    initialPartyId?: string
    // 本位币是数据(currencies.is_base)—— 客户端组件按 AGENTS.md 的规矩接成 prop
    baseCurrency: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createPayment, initialState)

    const [direction, setDirection] = useState<'in' | 'out'>(initialDirection)
    const [partyValue, setPartyValue] = useState(initialPartyId ? counterpartyValue(direction === 'in' ? 'customer' : 'supplier', initialPartyId) : '')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState('USD')
    const [fx, setFx] = useState('')
    const [bank, setBank] = useState('1010') // 初始币种 USD → 1010
    const [alloc, setAlloc] = useState<Record<string, string>>({})
    const [payDate, setPayDate] = useState(todayIsoLocal())
    // 汇率不再由本页计算 —— 向数据库要。null = 还没有结果(未查/查失败)
    const [autoFx, setAutoFx] = useState<number | null>(null)
    const [fxAsOf, setFxAsOf] = useState<string | null>(null)
    // 各【单据币种】在结算日的牌价 —— 用来把核销的单据额折成消耗的付款额
    const [docRates, setDocRates] = useState<Record<string, number>>({})
    // FIN-19:每个单据币种的牌价【取自哪一天】。回溯是有条件地被接受的,
    // 条件就是说出来 —— 一个不带日期的折算数字,和一个编出来的数字一样不可查。
    const [docAsOf, setDocAsOf] = useState<Record<string, string>>({})
    const [fxError, setFxError] = useState<string | null>(null)
    // 【单据币种】缺牌价也是缺牌价。原先 lookupRatesFor 的 error 被 `r.rates ?? {}`
    // 一把吞掉:docRates 空 → toPay 的 `?? payRate` 按 1:1 折 → 屏幕说 USD 1,400 只
    // 消耗 SGD 1,400 → 未冲销算成 0 → 超额护栏【不触发】→ 提交后服务端才抛
    // FX_RATE_MISSING。fxError 只盯付款币种,盯不到这一支,所以它要有自己的状态。
    const [docFxError, setDocFxError] = useState<string | null>(null)
    const [fxLoading, setFxLoading] = useState(false)

    // 方向切换清空往来单位与核销;换往来单位清空核销
    function onDirectionChange(d: 'in' | 'out') {
        setDirection(d)
        setPartyValue('')
        setAlloc({})
    }
    function onPartyChange(v: string) {
        setPartyValue(v)
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


    // PAYEE-1b:出款的往来对象有两种(供应商 / 员工),收款仍只有客户。
    // 【下拉的 value 带着种类】`kind:uuid` —— 一次选择就是一个完整答案,
    // 不存在"种类"与"id"两个字段互相矛盾的可能(库里那条 XOR 的表单形态)。
    // 过滤核销候选用的仍是【裸 uuid】,所以这里把两者分开拿。
    const selectedParty = parseCounterparty(partyValue)
    const partyId = selectedParty?.id ?? ''
    // ════════════════════════════════════════════════════════════════════════
    // 【这里曾经按币种过滤过 —— 那是修错了层】
    // 当时看到"页面列出了服务端会拒的选项",就让页面去迎合服务端。可那条服务端
    // 规则(ALLOC_CURRENCY_MISMATCH:USD 单只收 USD 付款)本身才是错的:
    // 欠 USD 6,000 的客户拿 SGD 付清,这张单就是清了 —— 拒绝它不是护栏,是缺功能。
    // FIN-16 撤掉了那条规则,过滤也随之撤掉。
    // 【留下的教训】"让页面与服务端一致"只在服务端是对的时候才对。页面提供了
    //  服务端会拒的东西,首先该问的是【那条规则对不对】,而不是默认页面错了。
    // ════════════════════════════════════════════════════════════════════════
    const items = (direction === 'in' ? arItems : apItems)
        .filter((i) => i.party_id === partyId)
    // 付款方向:该供应商可预付的采购单(单独一组,列在 AP 单据之上)
    // 同上:预付也不再按币种过滤(服务端改为把付款折进 PO 币种再比 1.5 倍上限)
    const pos = direction === 'out' ? poItems.filter((p) => p.party_id === partyId) : []
    // 单据币种的牌价(可能与付款币种不同 —— FIN-16)
    const docCcys = [...new Set([...items.map((i) => i.currency), ...pos.map((p) => p.currency)])]
        .filter(Boolean).sort().join(',')
    useEffect(() => {
        setDocRates({})
        setDocAsOf({})
        setDocFxError(null)
        if (!payDate || !docCcys) return
        let cancelled = false
        lookupRatesFor(docCcys.split(','), payDate, direction).then((r) => {
            if (cancelled) return
            // 【拒绝要浮上来】缺哪一天、哪个币种、取哪一侧,lookupRatesFor 已经说清楚了;
            // 这里只需要不把它丢掉,并且让提交按钮跟着停下。
            if (r.error) { setDocFxError(r.error); return }
            setDocRates(r.rates ?? {})
            setDocAsOf(r.asOf ?? {})
        })
        return () => { cancelled = true }
    }, [docCcys, payDate, direction])

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
    // ════════════════════════════════════════════════════════════════════════
    // 单据额 → 消耗的付款额。与 record_payment 同式:doc × rate(doc) / rate(pay);
    // 同币种时那边【根本不查汇率】(v_alloc_pay := v_alloc_usd),这里照抄。
    //
    // 【不知道就说不知道 —— 返回 null,不返回一个编出来的数】原先写的是
    //   docRates[docCcy] ?? payRate   和   effectiveFx ?? docRates[currency] ?? 1
    // 两个都是 FX 规则明令禁止的 `?? 1`:缺牌价时比值恰好是 1,于是 USD 单据看起来
    // 与付款等值。它不报错、不留痕,还顺手把超额护栏一起废掉(见 docFxError)。
    // ════════════════════════════════════════════════════════════════════════
    const payRate = effectiveFx        // null = 还不知道(跨币种未填成交价 / 牌价没查到)
    const toPay = (docCcy: string, amt: number): number | null => {
        if (amt === 0) return 0
        if (docCcy === currency) return amt
        const dr = docRates[docCcy]
        if (payRate === null || !dr) return null
        return round2(amt * dr / payRate)
    }

    // 核销合计有两个:单据币种口径(逐单据)与【付款币种】口径(与款额比较)。
    // 单据币种那一侧【按币种分开】—— 见下面 settlesByCcy;跨币种相加是没有意义的数。
    const consumedRows = [
        ...items.map((i) => toPay(i.currency, allocValue(i.doc_id))),
        ...pos.map((p) => toPay(p.currency, allocValue(p.po_id))),
    ]
    // 任何一行折不出来,合计就是【不知道】,不是"其余几行的和"
    const totalConsumed: number | null = consumedRows.includes(null)
        ? null
        : round2((consumedRows as number[]).reduce((s, v) => s + v, 0))

    // 核销到的单据额,【按单据币种分组】。原先这里是一个横跨币种的总和,
    // 一张 USD 单加一张 SGD 单会被直接相加 —— 那个数不代表任何东西。
    const settlesByCcy = (() => {
        const m = new Map<string, number>()
        const add = (ccy: string, v: number) => { if (v > 0) m.set(ccy, round2((m.get(ccy) ?? 0) + v)) }
        items.forEach((i) => add(i.currency, allocValue(i.doc_id)))
        pos.forEach((p) => add(p.currency, allocValue(p.po_id)))
        return [...m.entries()].sort(([a], [b]) => a.localeCompare(b))
    })()
    // 是否出现了跨币种核销 —— 决定要不要把"消耗"那一列显示出来
    const mixedCcy = items.some((i) => allocValue(i.doc_id) > 0 && i.currency !== currency)
        || pos.some((p) => allocValue(p.po_id) > 0 && p.currency !== currency)
    // 【与服务端同币种】record_payment 查的是 v_alloc_total > p_amount,两边都是
    // 【付款币种】。本页原来拿基准额减单据币种的核销额 —— 两种货币相减,
    // 操作员读到的数和服务端校验的数根本不是一回事。
    // 未核销 = 款额 − 【已消耗的付款额】(不是单据额合计 —— 跨币种时那是两种货币相减)
    const unallocated: number | null = totalConsumed === null
        ? null
        : round2((amountValid ? amountNum : 0) - totalConsumed)

    // fill:该行填到 min(未结额, 未冲销余额[不计本行])
    // 单据额 ← 付款额(toPay 的反函数),用于把"还剩多少款"换算成"还能核销多少单据额"
    const fromPay = (docCcy: string, amt: number): number | null => {
        if (amt === 0) return 0
        if (docCcy === currency) return amt
        const dr = docRates[docCcy]
        if (payRate === null || !dr) return null
        return round2(amt * payRate / dr)
    }
    // 折不出来就连"填满"也不能按 —— 填一个编出来的数,比不填坏得多
    const canFill = (docCcy: string) => docCcy === currency || (payRate !== null && !!docRates[docCcy])

    function fill(item: OpenItem) {
        // 【两边都要换算】others 是其它行消耗掉的【付款额】;剩余款额再换回单据币种,
        // 才能与 open_ccy(单据币种)比大小。原先两边直接相减,跨币种时按汇率错。
        const self = toPay(item.currency, allocValue(item.doc_id))
        if (totalConsumed === null || self === null) return
        const remainingPay = Math.max(0, round2((amountValid ? amountNum : 0) - (totalConsumed - self)))
        const remaining = fromPay(item.currency, remainingPay)
        if (remaining === null) return
        const v = Math.min(item.open_ccy, remaining)
        setAlloc((a) => ({ ...a, [item.doc_id]: v > 0 ? String(v) : '' }))
    }
    // 预付行没有单据上限(定金不是在还债)—— fill = 未冲销余额;1.5× 栏杆由 DB 把守
    function fillPo(p: PoItem) {
        const self = toPay(p.currency, allocValue(p.po_id))
        if (totalConsumed === null || self === null) return
        const remainingPay = Math.max(0, round2((amountValid ? amountNum : 0) - (totalConsumed - self)))
        const remaining = fromPay(p.currency, remainingPay)
        if (remaining === null) return
        setAlloc((a) => ({ ...a, [p.po_id]: remaining > 0 ? String(remaining) : '' }))
    }

    // 【每行的付款币种成本,边打字边出】操作员输入的是【单据币种】,而约束他的是
    // 付款额。1400 打在 USD 单上,右边立刻出现 "消耗 1,736.00 SGD" —— 单位是什么,
    // 不用解释,看一眼就知道。缺牌价时显示 —,绝不显示一个折不出来的数。
    function RowCost({ docCcy, docId }: { docCcy: string; docId: string }) {
        const v = allocValue(docId)
        if (v === 0 || docCcy === currency) return null
        const cost = toPay(docCcy, v)
        const rate = docRates[docCcy]
        const asOf = docAsOf[docCcy]
        // 【取自哪一天要看得见】与交易日不同时必须标出来 —— 那正是回溯当初被
        // 接受的条件。周五的价用在周六是对的,但操作员有权知道自己在看哪一天。
        const staleDate = !!asOf && !!payDate && asOf !== payDate
        return (
            <div className={'text-xs mt-1 font-mono ' + (cost === null ? 'text-red-600' : 'text-gray-500')}>
                {t('finance.rowCost', { amount: cost === null ? '—' : formatAmount(cost, currency) })}
                {/* 【PAY-1:那个红色的破折号此前一个字都不说】
                    cost 为 null 的意思很具体:这张单的币种在结算日【没有牌价】,
                    所以折不出它会消耗多少付款额 —— 而不是"金额是零"、也不是
                    "这一行不能核销"。人看见一个红破折号,唯一能做的只有猜。
                    补救也很具体:去 /finance/fx 把那一天的牌价录进去。
                    (服务端仍然会 FX_RATE_MISSING 兜底 —— 这一句是体贴,不是闸。) */}
                {cost === null && (
                    <span className="ml-1 font-sans text-red-700">
                        {t('finance.rowCostNoRate', { ccy: docCcy, date: payDate || '—' })}
                    </span>
                )}
                {cost !== null && rate && (
                    <span className="ml-1">@ {rate}</span>
                )}
                {cost !== null && staleDate && (
                    <span className="ml-1 px-1 rounded bg-amber-100 text-amber-800 font-sans">
                        {t('finance.fxLookup.asOf', { 0: asOf })}
                    </span>
                )}
            </div>
        )
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
                        name="counterparty"
                        required
                        value={partyValue}
                        onChange={(e) => onPartyChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('finance.selectCounterparty')}
                        </option>
                        {direction === 'in' ? (
                            customers.map((p) => (
                                <option key={p.id} value={counterpartyValue('customer', p.id)}>
                                    {p.name}
                                </option>
                            ))
                        ) : (
                            /* PAYEE-1b:付款方向 —— 供应商【或】员工(报销),两组选项一个下拉。
                               员工名单为空时那一组里放的是【一句话】,不是空白:
                               空下拉配死按钮正是 PAYEE-1a 不得不从报销页删掉的形状。 */
                            <CounterpartyOptions
                                suppliers={suppliers}
                                employees={employees}
                                supplierLabel={t('finance.counterpartyKind.supplier')}
                                employeeLabel={t('finance.counterpartyKind.employee')}
                                employeesEmptyLabel={t('finance.employeesEmpty')}
                                suppliersEmptyLabel={t('suppliers.pickerEmptyGoods')} />
                        )}
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
                                    {/* 【这两列不是同一种币】estimated_total_ccy 名字里带 usd,
                                        存的却是【单据币种】(create_purchase_order 全程不乘汇率,
                                        旧名见 docs/known-issues.md);prepaid_base 是【本位币】。
                                        并排、都不标币种,比未结那一列还容易读错 —— 各标各的。 */}
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(p.estimated_total_ccy, p.currency)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(p.prepaid_base, baseCurrency)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="alloc_id" value={p.po_id} />
                                        <input type="hidden" name="alloc_kind" value="purchase_order" />
                                        <div className="flex items-center gap-1">
                                            <DecimalInput
                                                name="alloc_amount"
                                                value={alloc[p.po_id] ?? ''}
                                                onChange={(raw) =>
                                                    setAlloc((a) => ({ ...a, [p.po_id]: raw }))
                                                }
                                                className="w-32 border border-gray-300 px-3 py-2 rounded"
                                            />
                                            <span className="text-xs text-gray-600 font-mono">{p.currency}</span>
                                            <button
                                                type="button"
                                                onClick={() => fillPo(p)}
                                                disabled={!canFill(p.currency)}
                                                className="ml-1 text-blue-600 hover:underline text-sm disabled:text-gray-400 disabled:no-underline"
                                            >
                                                {t('finance.fillAll')}
                                            </button>
                                        </div>
                                        <RowCost docCcy={p.currency} docId={p.po_id} />
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
                                    {/* 【每行都要带币种】FIN-16 之后这一列按设计就是混币种的,
                                        不标币种的混币种金额列不是显示瑕疵,是陷阱 */}
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatAmount(i.open_ccy, i.currency)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="alloc_id" value={i.doc_id} />
                                        <input type="hidden" name="alloc_kind" value={i.doc_kind} />
                                        {/* 上限不再由 max 属性约束(text 输入无此语义);
                                            超额由 DB 的 ALLOC_EXCEEDS 拦下,口径不变 */}
                                        <div className="flex items-center gap-1">
                                            <DecimalInput
                                                name="alloc_amount"
                                                value={alloc[i.doc_id] ?? ''}
                                                onChange={(raw) =>
                                                    setAlloc((a) => ({ ...a, [i.doc_id]: raw }))
                                                }
                                                className="w-32 border border-gray-300 px-3 py-2 rounded"
                                            />
                                            {/* 输入的是【单据币种】—— 把它写在框边上,而不是让人推断 */}
                                            <span className="text-xs text-gray-600 font-mono">{i.currency}</span>
                                            <button
                                                type="button"
                                                onClick={() => fill(i)}
                                                disabled={!canFill(i.currency)}
                                                className="ml-1 text-blue-600 hover:underline text-sm disabled:text-gray-400 disabled:no-underline"
                                            >
                                                {t('finance.fillAll')}
                                            </button>
                                        </div>
                                        <RowCost docCcy={i.currency} docId={i.doc_id} />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                ) : (
                    <p className="text-sm text-gray-500">{t('finance.noOpenItems')}</p>
                )
            )}

            {/* 缺牌价就【拒绝】—— 不回退 0、不回退 1。日期/币种/取哪一侧都说清楚。
                两支各有各的横幅:fxError 是【付款币种】折不出基准额;docFxError 是
                【单据币种】折不出消耗的付款额 —— 后者原先被静默吞掉。 */}
            {fxError && (
                <div className="rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {fxError}
                </div>
            )}
            {docFxError && (
                <div className="rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {docFxError}
                </div>
            )}

            {/* 实时合计:付款币种金额 / 折算基准额 / 冲销合计 / 未冲销 */}
            <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-8 text-sm items-center">
                <div>
                    {/* 【不能用 finance.colAmount】那个键写死了"(SGD)",而这里显示的是
                        【付款币种】的金额 —— 标签说 SGD、数字后面跟着 USD,自相矛盾 */}
                    <span className="text-gray-600 mr-1">{t('finance.paymentAmount')}:</span>
                    <span className="font-mono font-medium">
                        {formatMoneyBare(amountValid ? amountNum : 0, '同格内紧随其后的 {currency} 后缀')} {currency}
                    </span>
                </div>
                {/* 基准额单列一格,并标明是折算值 —— 与上面的付款币种金额不再混为一谈 */}
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.baseEquivalent')}:</span>
                    <span className="font-mono">
                        {payBase === null ? '—' : formatAmount(payBase, baseCurrency)}
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
                    {/* 【两边都摆出来】核销的是单据额;消耗的是款额。跨币种时这是两个数,
                        同币种时相等 —— 相等就不必重复显示。 */}
                    <span className="font-mono font-medium">
                        {totalConsumed === null ? '—' : formatAmount(totalConsumed, currency)}
                    </span>
                    {/* 【逐币种列出,不再求一个总和】原先这里是 Σ(各单据币种的核销额),
                        一张 USD 单加一张 SGD 单直接相加。只核销一张时看不出来,两张就
                        是个没有单位的数。分币种写出来,加法就无处可做。 */}
                    {mixedCcy && (
                        <span className="ml-2 text-xs text-gray-500">
                            {t('finance.settlesDocuments', {
                                list: settlesByCcy.map(([c, v]) => formatAmount(v, c)).join(' + '),
                            })}
                        </span>
                    )}
                </div>
                <div className={unallocated !== null && unallocated < 0 ? 'text-red-600' : 'text-gray-500'}>
                    <span className="mr-1">{t('finance.unallocated')}:</span>
                    <span className="font-mono">
                        {unallocated === null ? '—' : formatAmount(unallocated, currency)}
                    </span>
                    {unallocated !== null && unallocated < 0 && (
                        <span className="ml-2 text-xs">{t('finance.overAllocated')}</span>
                    )}
                </div>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={
                        isPending || fxLoading || effectiveFx === null
                        // 单据币种缺牌价 → 消耗额算不出 → 超额护栏无从判断。
                        // 这一支原先漏了,于是"折不出来"的表单照样可以提交。
                        || docFxError !== null || unallocated === null || unallocated < 0
                    }
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
