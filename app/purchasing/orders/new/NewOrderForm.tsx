'use client'

// 新建采购单表单。
//   * 头部:供应商(选定后,若其设有默认付款条款模板且用户尚未动过计划区,自动套用)、
//     日期、币种(非 USD 出汇率)、贸易术语、备注、条款正文。
//   * 明细行(≥1):物料 / 数量 / 单位 / 计价公式(可选)/ 估算单价;每行折叠的
//     "预计化验"面板(七金属含量,空 = 没测);公式 + 化验都有时出"按化验估算"按钮 ——
//     调 calculate_metal_price(服务端,与计价器同源),回填单价并摊开明细,数字可解释。
//   * 付款计划(可选,空表合法):套用模板 или 手工编辑;fixed_date 期在这里取
//     【绝对日期】(模板里的偏移天数在套用时按下单日换算)。
//   * 实时合计:行金额 / 单据估算总额 / 各期折算金额(比例期按估算总额换算成钱 ——
//     计划要能用钱读,不能只有百分比)。
//
// CCY-1:这张表里【也是两种口径】。行金额 / 各期金额 / 估算总额都是单据币种
// (头部那个下拉当场就能改),它们各自把 currency 写出来 —— 一个可以随时被改掉的
// 下拉当不了"币种写在这儿了"的凭据。而"按化验估算"摊开的那块是 calculate_metal_price
// 的原始输出,【行情口径,恒为 USD】(见 check-currency-literals 的 ALLOWLIST 理由),
// 那块自己每行都写着 USD,所以留裸数字并指着它。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import DecimalInput, { parseDecimal } from '@/app/components/forms/DecimalInput'
import { METAL_OPTIONS } from '@/app/metal-prices/options'
import type { CalcResult } from '@/app/pricing/calculator/actions'
import {
    createOrder,
    computeLineEstimate,
    type CreateOrderState,
    type OrderLineInput,
    type OrderTermInput,
} from './actions'

const initialState: CreateOrderState = {}

export type SupplierOption = { id: string; name: string; default_template_id: string | null }
export type MaterialOption = { id: string; label: string }
export type FormulaOption = { id: string; label: string }
export type TemplateOption = {
    id: string
    name: string
    lines: {
        label: string
        percentage: number | null
        fixed_amount_ccy: number | null
        trigger_event: string
        days_offset: number | null
    }[]
}

type LineRow = OrderLineInput & { assayOpen: boolean; calc: CalcResult | null; calcOpen: boolean
    calcError: string; calcFx: number | null; calcFxAsOf: string | null
    // FIN-26:价格框里的数【现在还是】估算按钮算出的那个 —— 手改一个字符就翻 false。
    // 出处是记录不是推断:提交时 computed 行带全套重导出依据(calc + fx)。
    priceComputed: boolean }

const TRIGGER_OPTIONS = ['on_order', 'on_shipment', 'on_arrival', 'post_assay', 'fixed_date'] as const

function todayIsoLocal(): string {
    const d = new Date()
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

// 下单日 + N 天 → YYYY-MM-DD(模板的 fixed_date 偏移换算;按本地日期,与下单日同口径)
function addDays(iso: string, days: number): string {
    const d = new Date(iso + 'T00:00:00')
    if (Number.isNaN(d.getTime())) return ''
    d.setDate(d.getDate() + days)
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

const round2 = (n: number) => Math.round(n * 100) / 100

function emptyLine(): LineRow {
    return {
        material_id: '',
        quantity: '',
        unit: 'kg',
        formula_id: '',
        est_price: '',
        priceComputed: false,
        assay: {},
        assayOpen: false,
        calc: null,
        calcOpen: false,
        calcError: '',
        calcFx: null,
        calcFxAsOf: null,
    }
}

function emptyTerm(): OrderTermInput {
    return { label: '', mode: 'percentage', percentage: '', fixed_amount: '', trigger_event: 'on_order', due_date: '' }
}

export default function NewOrderForm({
    suppliers,
    materials,
    formulas,
    templates,
    baseCurrency,
}: {
    suppliers: SupplierOption[]
    materials: MaterialOption[]
    formulas: FormulaOption[]
    templates: TemplateOption[]
    baseCurrency: string
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(createOrder, initialState)

    const [supplierId, setSupplierId] = useState('')
    const [orderDate, setOrderDate] = useState(todayIsoLocal())
    const [currency, setCurrency] = useState('USD')
    const [lines, setLines] = useState<LineRow[]>([emptyLine()])
    const [terms, setTerms] = useState<OrderTermInput[]>([])
    // 计划区一经手动编辑(含手选模板),换供应商不再自动覆盖 —— 用户的输入优先
    const [termsEdited, setTermsEdited] = useState(false)
    const [templateSel, setTemplateSel] = useState('')

    // 模板行 → 计划行(fixed_date:下单日 + 偏移 → 绝对日期)
    function termsFromTemplate(tpl: TemplateOption, baseDate: string): OrderTermInput[] {
        return tpl.lines.map((l) => ({
            label: l.label,
            mode: l.percentage !== null ? ('percentage' as const) : ('fixed' as const),
            percentage: l.percentage !== null ? String(l.percentage) : '',
            fixed_amount: l.fixed_amount_ccy !== null ? String(l.fixed_amount_ccy) : '',
            trigger_event: l.trigger_event,
            due_date: l.trigger_event === 'fixed_date' ? addDays(baseDate, l.days_offset ?? 0) : '',
        }))
    }

    function onSupplierChange(id: string) {
        setSupplierId(id)
        if (termsEdited) return
        const tplId = suppliers.find((s) => s.id === id)?.default_template_id
        const tpl = tplId ? templates.find((x) => x.id === tplId) : undefined
        if (tpl) {
            setTerms(termsFromTemplate(tpl, orderDate))
            setTemplateSel(tpl.id)
        }
    }

    function onApplyTemplate(id: string) {
        setTemplateSel(id)
        const tpl = templates.find((x) => x.id === id)
        if (tpl) {
            setTerms(termsFromTemplate(tpl, orderDate))
            setTermsEdited(true) // 手选模板 = 明确表态,换供应商不再覆盖
        }
    }

    function patchLine(i: number, patch: Partial<LineRow>) {
        setLines((ls) => ls.map((l, j) => (j === i ? { ...l, ...patch } : l)))
    }
    function patchTerm(i: number, patch: Partial<OrderTermInput>) {
        setTermsEdited(true)
        setTerms((ts) => ts.map((l, j) => (j === i ? { ...l, ...patch } : l)))
    }

    async function onComputeEstimate(i: number) {
        const l = lines[i]
        const qty = parseDecimal(l.quantity)
        const assay = Object.entries(l.assay)
            .map(([metal, raw]) => ({ metal, content_pct: parseDecimal(raw) }))
            .filter((a): a is { metal: string; content_pct: number } => a.content_pct !== null)
        patchLine(i, { calcError: '' })
        const res = await computeLineEstimate({
            formulaId: l.formula_id, quantity: qty ?? 0, assay,
            currency, orderDate,
        })
        if (res.error) {
            patchLine(i, { calcError: res.error, calc: null, calcOpen: false })
        } else if (res.result) {
            // 【填进去的是折成单据币种的价】公式算的是 USD/kg;单据是 SGD 时直接
            // 填 USD 数字就等于报低约四分之一。换算在服务端做,这里只用结果。
            patchLine(i, {
                est_price: String(res.unitPriceDoc ?? res.result.unit_price_usd_per_kg),
                priceComputed: true,
                calc: res.result,
                calcFx: res.fxUsed ?? null,
                calcFxAsOf: res.fxAsOf ?? null,
                calcOpen: true,
                calcError: '',
            })
        }
    }

    // 提交负载(去掉纯 UI 字段)
    const linesPayload: OrderLineInput[] = lines.map((l) => ({
        material_id: l.material_id, quantity: l.quantity, unit: l.unit,
        formula_id: l.formula_id, est_price: l.est_price, assay: l.assay,
        // FIN-26:出处随行走。computed = 按钮算的且没被手改过;有价而非 computed
        // 即 manual。依据 = 完整 CalcResult(逐金属行情与日期、公式参数)+ 汇率。
        ...(l.est_price.trim() !== ''
            ? l.priceComputed && l.calc
                ? { price_source: 'computed' as const,
                    price_provenance: { calc: l.calc, fx_factor: l.calcFx, fx_as_of: l.calcFxAsOf,
                                        doc_price: l.est_price, currency } }
                : { price_source: 'manual' as const }
            : {}),
    }))

    const lineAmount = (l: LineRow) => {
        const qty = parseDecimal(l.quantity)
        const price = parseDecimal(l.est_price)
        return qty !== null && price !== null ? round2(qty * price) : 0
    }
    const estTotal = round2(lines.reduce((s, l) => s + lineAmount(l), 0))

    const termAmount = (l: OrderTermInput) => {
        if (l.mode === 'fixed') return parseDecimal(l.fixed_amount) ?? 0
        const pct = parseDecimal(l.percentage)
        return pct !== null ? round2((estTotal * pct) / 100) : 0
    }
    const pctTotal = round2(
        terms.reduce((s, l) => (l.mode === 'percentage' ? s + (parseDecimal(l.percentage) ?? 0) : s), 0)
    )
    const pctOver = pctTotal > 100

    const assayCount = (l: LineRow) =>
        Object.values(l.assay).filter((v) => parseDecimal(v) !== null).length

    return (
        <form action={formAction} className="space-y-6">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <input type="hidden" name="lines_json" value={JSON.stringify(linesPayload)} />
            <input type="hidden" name="terms_json" value={JSON.stringify(terms)} />

            {/* ── 头部 ── */}
            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.form.supplier')} <span className="text-red-600">*</span>
                    </label>
                    <select
                        name="supplier_id"
                        required
                        value={supplierId}
                        onChange={(e) => onSupplierChange(e.target.value)}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="" disabled>
                            {t('finance.selectCounterparty')}
                        </option>
                        {suppliers.map((s) => (
                            <option key={s.id} value={s.id}>
                                {s.name}
                            </option>
                        ))}
                    </select>
                    {/* SUP-TYPE-1b:同上 —— 只列供货的供应商,空了要说出原因。 */}
                    {suppliers.length === 0 && (
                        <p className="text-xs text-amber-700 mt-1">
                            {t('suppliers.noGoodsSuppliers')}{' '}
                            <Link href="/suppliers" className="underline">
                                {t('suppliers.noGoodsSuppliersLink')}
                            </Link>
                        </p>
                    )}
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('purchasing.form.orderDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="order_date"
                        required
                        value={orderDate}
                        onChange={(e) => setOrderDate(e.target.value)}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('purchasing.form.expectedDelivery')}</label>
                    <input
                        type="date"
                        name="expected_delivery"
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('purchasing.form.currency')}</label>
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
                {/* FIN-0:外币按下单日行方卖出价(tt_sell)自动估值,当天没牌价直接拒 */}
                {currency !== baseCurrency && (
                    <p className="text-xs text-gray-500 self-end pb-2 max-w-56">{t('common.fxBoardRateHint')}</p>
                )}
                <div>
                    <label className="block text-sm font-medium mb-1">{t('purchasing.form.incoterm')}</label>
                    <input type="text" name="incoterm" className="w-28 border border-gray-300 px-3 py-2 rounded" />
                </div>
            </div>
            <div className="flex flex-wrap gap-4">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('purchasing.form.notes')}</label>
                    <input type="text" name="notes" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-sm font-medium mb-1">{t('purchasing.form.termsText')}</label>
                    <input type="text" name="terms_text" className="w-full border border-gray-300 px-3 py-2 rounded" />
                </div>
            </div>

            {/* ── 明细行 ── */}
            <h2 className="font-bold">{t('purchasing.form.lines')}</h2>
            <div className="space-y-3">
                {lines.map((l, i) => (
                    <div key={i} className="border border-gray-300 rounded p-3 space-y-2">
                        <div className="flex flex-wrap gap-3 items-end">
                            <div className="flex-1 min-w-[14rem]">
                                <label className="block text-xs text-gray-600 mb-1">
                                    {t('purchasing.colMaterial')} <span className="text-red-600">*</span>
                                </label>
                                <select
                                    required
                                    value={l.material_id}
                                    onChange={(e) => patchLine(i, { material_id: e.target.value })}
                                    className="w-full border border-gray-300 px-2 py-1.5 rounded"
                                >
                                    <option value="" disabled>
                                        —
                                    </option>
                                    {materials.map((m) => (
                                        <option key={m.id} value={m.id}>
                                            {m.label}
                                        </option>
                                    ))}
                                </select>
                            </div>
                            <div>
                                <label className="block text-xs text-gray-600 mb-1">
                                    {t('purchasing.colQuantity')} <span className="text-red-600">*</span>
                                </label>
                                <DecimalInput
                                    required
                                    value={l.quantity}
                                    onChange={(v) => patchLine(i, { quantity: v })}
                                    className="w-28 border border-gray-300 px-2 py-1.5 rounded"
                                />
                            </div>
                            <div>
                                <label className="block text-xs text-gray-600 mb-1">{t('inbound.form.unit')}</label>
                                <input
                                    type="text"
                                    value={l.unit}
                                    onChange={(e) => patchLine(i, { unit: e.target.value })}
                                    className="w-16 border border-gray-300 px-2 py-1.5 rounded"
                                />
                            </div>
                            <div className="min-w-[12rem]">
                                <label className="block text-xs text-gray-600 mb-1">{t('purchasing.colFormula')}</label>
                                <select
                                    value={l.formula_id}
                                    onChange={(e) => patchLine(i, {
                                        formula_id: e.target.value,
                                        // FIN-26 Part D:选了公式就摊开化验面板 —— 没有含量,
                                        // 公式什么都算不出;把唯一让它工作的输入折叠起来,
                                        // 正是"没有含量字段"误会(和手敲 8.0000)的成因。
                                        ...(e.target.value ? { assayOpen: true } : {}),
                                    })}
                                    className="w-full border border-gray-300 px-2 py-1.5 rounded"
                                >
                                    <option value="">—</option>
                                    {formulas.map((f) => (
                                        <option key={f.id} value={f.id}>
                                            {f.label}
                                        </option>
                                    ))}
                                </select>
                            </div>
                            <div>
                                <label className="block text-xs text-gray-600 mb-1">{t('purchasing.colUnitPrice')}</label>
                                <DecimalInput
                                    value={l.est_price}
                                    onChange={(v) => patchLine(i, { est_price: v, priceComputed: false })}
                                    className="w-28 border border-gray-300 px-2 py-1.5 rounded"
                                />
                            </div>
                            <div className="text-sm text-gray-600 pb-1.5">
                                {t('purchasing.colAmount')}:{' '}
                                <span className="font-mono font-medium">{formatAmount(lineAmount(l), currency)}</span>
                            </div>
                            <button
                                type="button"
                                onClick={() => setLines((ls) => (ls.length > 1 ? ls.filter((_, j) => j !== i) : ls))}
                                disabled={lines.length === 1}
                                className="text-red-600 hover:underline text-sm pb-1.5 disabled:text-gray-300 disabled:no-underline"
                            >
                                {t('purchasing.form.removeLine')}
                            </button>
                        </div>

                        {/* 预计化验(折叠;空 = 没测。最终计价以到货批次的实际化验为准)*/}
                        <div>
                            <button
                                type="button"
                                onClick={() => patchLine(i, { assayOpen: !l.assayOpen })}
                                className="text-blue-600 hover:underline text-sm"
                            >
                                {l.assayOpen ? '▾' : '▸'} {t('purchasing.form.expectedAssay')}
                                {assayCount(l) > 0 && (
                                    <span className="ml-1 text-gray-500">({assayCount(l)})</span>
                                )}
                            </button>
                            {l.assayOpen && (
                                <div className="mt-2 flex flex-wrap gap-3">
                                    {METAL_OPTIONS.map((m) => (
                                        <label key={m.value} className="flex items-center gap-1 text-sm">
                                            <span className="w-8 text-gray-600">{t(m.labelKey)}</span>
                                            <DecimalInput
                                                value={l.assay[m.value] ?? ''}
                                                onChange={(v) =>
                                                    patchLine(i, { assay: { ...l.assay, [m.value]: v } })
                                                }
                                                className="w-20 border border-gray-300 px-2 py-1 rounded"
                                            />
                                            <span className="text-gray-400">%</span>
                                        </label>
                                    ))}
                                </div>
                            )}
                        </div>

                        {/* 按化验估算:公式 + 化验都有才出现;结果摊开,数字可解释 */}
                        {l.formula_id && assayCount(l) > 0 && (
                            <div>
                                <button
                                    type="button"
                                    onClick={() => onComputeEstimate(i)}
                                    className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm"
                                >
                                    {t('purchasing.computeEstimate')}
                                </button>
                                {l.calcError && <span className="ml-2 text-sm text-red-600">{l.calcError}</span>}
                                {l.calc && (
                                    <button
                                        type="button"
                                        onClick={() => patchLine(i, { calcOpen: !l.calcOpen })}
                                        className="ml-2 text-blue-600 hover:underline text-sm"
                                    >
                                        {l.calcOpen ? '▾' : '▸'} {formatMoneyBare(l.calc.unit_price_usd_per_kg, '紧跟其后的 USD/kg')} USD/kg
                                        {l.calcFx && l.calcFx !== 1 && (
                                            <span className="ml-1 text-xs text-gray-500">
                                                × {l.calcFx.toFixed(4)} = {l.est_price} {currency}/kg
                                                {l.calcFxAsOf && ' ' + t('finance.fxLookup.asOf', { 0: l.calcFxAsOf })}
                                            </span>
                                        )}
                                    </button>
                                )}
                                {l.calc && l.calcOpen && (
                                    <div className="mt-2 bg-gray-50 rounded p-3 text-xs space-y-1">
                                        <p className="text-gray-600">
                                            {l.calc.formula_code} — {l.calc.formula_name} · {l.calc.reference_date}
                                        </p>
                                        <table className="border-collapse">
                                            <tbody>
                                                {l.calc.lines.map((cl) => (
                                                    <tr key={cl.metal}>
                                                        <td className="pr-3">{t('metals.' + cl.metal)}</td>
                                                        <td className="pr-3 font-mono">{cl.content_pct}%</td>
                                                        <td className="pr-3 font-mono">× {cl.payable_pct}%</td>
                                                        <td className="pr-3 font-mono text-right">
                                                            {cl.price_usd_per_tonne !== null
                                                                ? formatMoneyBare(cl.price_usd_per_tonne, '本块末行的「… = … USD」—— 计价明细整块是行情口径 USD') + '/t'
                                                                : '—'}
                                                        </td>
                                                        <td className="font-mono text-right">
                                                            {formatMoneyBare(cl.metal_value_usd, '本块末行的「… = … USD」—— 计价明细整块是行情口径 USD')}
                                                        </td>
                                                    </tr>
                                                ))}
                                            </tbody>
                                        </table>
                                        <p className="font-mono text-gray-700">
                                            {formatMoneyBare(l.calc.gross_value_usd, '同一行末尾的 USD')} − {formatMoneyBare(l.calc.treatment_usd, '同一行末尾的 USD')}{' '}
                                            − {formatMoneyBare(l.calc.discount_usd, '同一行末尾的 USD')} = {formatMoneyBare(l.calc.net_value_usd, '同一行末尾的 USD')} USD →{' '}
                                            <span className="font-medium">
                                                {formatMoneyBare(l.calc.unit_price_usd_per_kg, '同一行的 USD —— 折算成单据币种的价在上面那行')} /kg
                                            </span>
                                        </p>
                                    </div>
                                )}
                            </div>
                        )}
                    </div>
                ))}
            </div>
            <button
                type="button"
                onClick={() => setLines((ls) => [...ls, emptyLine()])}
                className="text-blue-600 hover:underline text-sm"
            >
                {t('purchasing.form.addLine')}
            </button>

            {/* ── 付款计划(可选)── */}
            <div className="flex items-center gap-4 pt-2">
                <h2 className="font-bold">{t('purchasing.form.paymentTerms')}</h2>
                <select
                    value={templateSel}
                    onChange={(e) => onApplyTemplate(e.target.value)}
                    className="border border-gray-300 px-2 py-1 rounded text-sm"
                >
                    <option value="">{t('purchasing.applyTemplate')}</option>
                    {templates.map((tpl) => (
                        <option key={tpl.id} value={tpl.id}>
                            {tpl.name}
                        </option>
                    ))}
                </select>
            </div>
            {terms.length > 0 && (
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left w-10">{t('purchasing.colSeq')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colLabel')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colShare')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colAmount')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colTrigger')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left w-16" />
                        </tr>
                    </thead>
                    <tbody>
                        {terms.map((l, i) => (
                            <tr key={i}>
                                <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{i + 1}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <input
                                        type="text"
                                        value={l.label}
                                        onChange={(e) => patchTerm(i, { label: e.target.value })}
                                        className="w-full border border-gray-300 px-2 py-1 rounded"
                                    />
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <div className="flex items-center gap-2">
                                        <label className="flex items-center gap-1 text-sm">
                                            <input
                                                type="radio"
                                                checked={l.mode === 'percentage'}
                                                onChange={() => patchTerm(i, { mode: 'percentage' })}
                                            />
                                            {t('purchasing.form.modePct')}
                                        </label>
                                        <label className="flex items-center gap-1 text-sm">
                                            <input
                                                type="radio"
                                                checked={l.mode === 'fixed'}
                                                onChange={() => patchTerm(i, { mode: 'fixed' })}
                                            />
                                            {t('purchasing.form.modeFixed')}
                                        </label>
                                        {l.mode === 'percentage' ? (
                                            <DecimalInput
                                                value={l.percentage}
                                                onChange={(v) => patchTerm(i, { percentage: v })}
                                                className="w-20 border border-gray-300 px-2 py-1 rounded"
                                            />
                                        ) : (
                                            <DecimalInput
                                                value={l.fixed_amount}
                                                onChange={(v) => patchTerm(i, { fixed_amount: v })}
                                                className="w-24 border border-gray-300 px-2 py-1 rounded"
                                            />
                                        )}
                                    </div>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                    {formatAmount(termAmount(l), currency)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <select
                                        value={l.trigger_event}
                                        onChange={(e) => patchTerm(i, { trigger_event: e.target.value })}
                                        className="border border-gray-300 px-2 py-1 rounded"
                                    >
                                        {TRIGGER_OPTIONS.map((ev) => (
                                            <option key={ev} value={ev}>
                                                {t('purchasing.trigger.' + ev)}
                                            </option>
                                        ))}
                                    </select>
                                    {l.trigger_event === 'fixed_date' && (
                                        <input
                                            type="date"
                                            value={l.due_date}
                                            onChange={(e) => patchTerm(i, { due_date: e.target.value })}
                                            className="ml-2 border border-gray-300 px-2 py-1 rounded"
                                        />
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <button
                                        type="button"
                                        onClick={() => {
                                            setTermsEdited(true)
                                            setTerms((ts) => ts.filter((_, j) => j !== i))
                                        }}
                                        className="text-red-600 hover:underline text-sm"
                                    >
                                        {t('purchasing.form.removeLine')}
                                    </button>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
            <div className="flex items-center justify-between">
                <button
                    type="button"
                    onClick={() => {
                        setTermsEdited(true)
                        setTerms((ts) => [...ts, emptyTerm()])
                    }}
                    className="text-blue-600 hover:underline text-sm"
                >
                    {t('purchasing.form.addTerm')}
                </button>
                {pctOver ? (
                    <p className="text-sm text-red-600">
                        {t('purchasing.errors.TERMS_PCT_EXCEEDS', { 0: pctTotal })}
                    </p>
                ) : pctTotal > 0 && pctTotal < 100 ? (
                    <p className="text-sm text-amber-700">{t('purchasing.pctUnder', { total: pctTotal })}</p>
                ) : null}
            </div>

            {/* ── 实时合计 ── */}
            <div className="bg-gray-50 rounded p-4 text-sm">
                <span className="text-gray-600 mr-1">{t('purchasing.colEstimatedTotal')}:</span>
                <span className="font-mono font-medium">{formatAmount(estTotal, currency)}</span>
            </div>

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending || pctOver}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('purchasing.form.submitting') : t('purchasing.form.submit')}
                </button>
                <Link
                    href="/purchasing/orders"
                    className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
