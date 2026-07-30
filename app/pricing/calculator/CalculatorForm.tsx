'use client'

// 计价器:谈判时真正会用的那个页面。
// 输入公式 / 数量 / 计价日 / 七个金属的化验含量(留空 = 没测,整行忽略),
// 点"计算"走服务端动作调 DB 函数,把返回的【完整明细】原样摊开 —— 客户端不做任何算术。
// 支持 ?formula=&quantity=&ni=&co=… 预填,便于从批次页直接带着化验结果跳进来。
import { useActionState, useState } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd } from '@/lib/format'
import DecimalInput from '@/app/components/forms/DecimalInput'
import { METAL_OPTIONS } from '@/app/metal-prices/options'
import { calculatePrice, type CalculatorState, type CalcLine } from './actions'

const initialState: CalculatorState = {}

export type FormulaOption = {
    id: string
    code: string
    name: string
    direction: string
}

export default function CalculatorForm({
    formulas,
    prefill,
}: {
    formulas: FormulaOption[]
    prefill: { formulaId: string; quantity: string; date: string; assay: Record<string, string> }
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(calculatePrice, initialState)

    const [formulaId, setFormulaId] = useState(prefill.formulaId)
    const [quantity, setQuantity] = useState(prefill.quantity)
    const [assay, setAssay] = useState<Record<string, string>>(prefill.assay)
    const [copied, setCopied] = useState(false)

    const res = state.result

    // 按方向分组,谈采购时不会误选销售公式
    const grouped = [
        { key: 'purchase', items: formulas.filter((f) => f.direction === 'purchase') },
        { key: 'sale', items: formulas.filter((f) => f.direction === 'sale') },
        { key: 'both', items: formulas.filter((f) => f.direction === 'both') },
    ].filter((g) => g.items.length > 0)

    // 纯文本明细:直接粘进给供应商的邮件里,所以只用金属代码 + 数字 + 英文标签
    function breakdownText(): string {
        if (!res) return ''
        const L: string[] = []
        L.push(`${res.formula_code} ${res.formula_name}`)
        L.push(`Reference date: ${res.reference_date}   Quantity: ${res.quantity_kg} kg`)
        L.push('')
        for (const l of res.lines) {
            const price =
                l.price_usd_per_tonne == null
                    ? 'no price'
                    : `${l.price_usd_per_tonne} USD/t${l.price_date ? ` @ ${l.price_date}` : ''}${
                          l.price_from ? ` (${l.price_from}..${l.price_to})` : ''
                      }`
            L.push(
                `${l.metal.toUpperCase().padEnd(3)} content ${l.content_pct}%  payable ${l.payable_pct}%  ` +
                    `contained ${l.contained_kg} kg  payable ${l.payable_kg} kg  ${price}  = ${formatUsd(l.metal_value_usd)} USD`
            )
        }
        L.push('')
        L.push(`Gross value:     ${formatUsd(res.gross_value_usd)} USD`)
        L.push(`Treatment:      -${formatUsd(res.treatment_usd)} USD`)
        L.push(`Discount:       -${formatUsd(res.discount_usd)} USD`)
        L.push(`Net value:       ${formatUsd(res.net_value_usd)} USD`)
        L.push(`Unit price:      ${res.unit_price_usd_per_kg} USD/kg`)
        if (res.skipped_metals.length) L.push(`No price: ${res.skipped_metals.join(', ')}`)
        if (res.unpaid_metals.length) L.push(`Not payable: ${res.unpaid_metals.join(', ')}`)
        return L.join('\n')
    }

    async function copyBreakdown() {
        try {
            await navigator.clipboard.writeText(breakdownText())
            setCopied(true)
            setTimeout(() => setCopied(false), 2000)
        } catch {
            /* 剪贴板不可用(非安全上下文)时静默失败 —— 明细本身仍在页面上 */
        }
    }

    const priceCell = (l: CalcLine) => {
        if (l.price_usd_per_tonne == null) return <span className="text-gray-400">—</span>
        return (
            <>
                <span className="font-mono">{formatUsd(l.price_usd_per_tonne)}</span>
                <span className="text-gray-500 text-xs ml-2">
                    {l.price_date ?? (l.price_from ? `${l.price_from} – ${l.price_to}` : '')}
                </span>
            </>
        )
    }

    return (
        <div className="space-y-6">
            <form action={formAction} className="space-y-4">
                {state.error && (
                    <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                        {state.error}
                    </div>
                )}

                <div className="flex flex-wrap gap-4">
                    <div className="flex-1 min-w-[18rem]">
                        <label className="block text-sm font-medium mb-1">
                            {t('pricing.calcFormula')} <span className="text-red-600">*</span>
                        </label>
                        <select
                            name="formula_id"
                            required
                            value={formulaId}
                            onChange={(e) => setFormulaId(e.target.value)}
                            className="w-full border border-gray-300 px-3 py-2 rounded"
                        >
                            <option value="" disabled>
                                {t('pricing.form.name')}
                            </option>
                            {grouped.map((g) => (
                                <optgroup key={g.key} label={t('pricing.direction.' + g.key)}>
                                    {g.items.map((f) => (
                                        <option key={f.id} value={f.id}>
                                            {f.code} — {f.name}
                                        </option>
                                    ))}
                                </optgroup>
                            ))}
                        </select>
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('pricing.calcQuantity')} <span className="text-red-600">*</span>
                        </label>
                        <DecimalInput
                            name="quantity_kg"
                            required
                            value={quantity}
                            onChange={setQuantity}
                            className="w-36 border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                    <div>
                        <label className="block text-sm font-medium mb-1">
                            {t('pricing.calcDate')} <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="date"
                            name="reference_date"
                            required
                            defaultValue={prefill.date}
                            className="border border-gray-300 px-3 py-2 rounded"
                        />
                    </div>
                </div>

                <div>
                    <h2 className="text-lg font-semibold mb-2">{t('pricing.calcAssay')}</h2>
                    <table className="w-full border-collapse border border-gray-300 max-w-md">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.form.colMetal')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('pricing.colContent')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {METAL_OPTIONS.map((opt) => (
                                <tr key={opt.value}>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {t(opt.labelKey)}
                                        <span className="text-gray-400 font-mono text-xs ml-2">{opt.value}</span>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <input type="hidden" name="assay_metal" value={opt.value} />
                                        <DecimalInput
                                            name="assay_content"
                                            value={assay[opt.value] ?? ''}
                                            onChange={(raw) => setAssay((a) => ({ ...a, [opt.value]: raw }))}
                                            className="w-28 border border-gray-300 px-3 py-2 rounded"
                                        />
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>

                <button
                    type="submit"
                    disabled={isPending}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('pricing.calcButton')}
                </button>
            </form>

            {/* 计价明细 */}
            {res && (
                <section className="border-t pt-6">
                    <div className="flex justify-between items-center mb-3">
                        <h2 className="text-xl font-bold">{t('pricing.calcResult')}</h2>
                        <button
                            type="button"
                            onClick={copyBreakdown}
                            className="border border-gray-300 px-3 py-2 rounded hover:bg-gray-50 text-sm"
                        >
                            {copied ? t('pricing.copied') : t('pricing.copyBreakdown')}
                        </button>
                    </div>

                    <p className="text-sm text-gray-600 mb-3">
                        <span className="font-mono">{res.formula_code}</span> {res.formula_name}
                        <span className="mx-2">·</span>
                        {res.price_basis === 'average'
                            ? t('pricing.basis.average', { days: res.average_days ?? 0 })
                            : t('pricing.basis.spot')}
                        <span className="mx-2">·</span>
                        {res.reference_date}
                        <span className="mx-2">·</span>
                        <span className="font-mono">{res.quantity_kg} kg</span>
                    </p>

                    {res.negative_value && (
                        <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-3 text-sm">
                            {t('pricing.negativeValue')}
                        </div>
                    )}
                    {res.skipped_metals.length > 0 && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-3 text-sm">
                            {t('pricing.skippedNote', { metals: res.skipped_metals.join(', ') })}
                        </div>
                    )}
                    {res.unpaid_metals.length > 0 && (
                        <p className="text-sm text-gray-500 mb-3">
                            {t('pricing.unpaidNote', { metals: res.unpaid_metals.join(', ') })}
                        </p>
                    )}

                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('pricing.form.colMetal')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colContent')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.form.colPayable')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colContained')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colPayableKg')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('pricing.colPrice')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('pricing.colValue')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {res.lines.map((l) => (
                                <tr key={l.metal}>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {t('metals.' + l.metal)}
                                        <span className="text-gray-400 font-mono text-xs ml-2">{l.metal}</span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.content_pct}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.payable_pct}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.contained_kg}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">{l.payable_kg}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-sm">{priceCell(l)}</td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {formatUsd(l.metal_value_usd)}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>

                    <div className="mt-4 max-w-md ml-auto text-sm space-y-1">
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('pricing.grossValue')}</span>
                            <span className="font-mono">{formatUsd(res.gross_value_usd)}</span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('pricing.treatmentCharge')}</span>
                            <span className="font-mono">−{formatUsd(res.treatment_usd)}</span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('pricing.discountAmount')}</span>
                            <span className="font-mono">−{formatUsd(res.discount_usd)}</span>
                        </div>
                        <div className="flex justify-between border-t pt-1 font-bold">
                            <span>{t('pricing.netValue')}</span>
                            <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                                {formatUsd(res.net_value_usd)}
                            </span>
                        </div>
                        <div className="flex justify-between font-bold">
                            <span>{t('pricing.unitPrice')}</span>
                            <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                                {res.unit_price_usd_per_kg}
                            </span>
                        </div>
                    </div>
                </section>
            )}
        </div>
    )
}
