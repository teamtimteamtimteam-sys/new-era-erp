'use client'

// 计价明细的共享呈现(逐金属行 + 汇总)。计价器页最先长出这套表格,化验录入的
// 实时预览与化验详情的"立即应用"预览要显示的是【同一份东西】—— 抽出来共用,
// 免得两处慢慢长歪。客户端在这里【不做任何算术】:所有数字都来自
// calculate_metal_price 的返回,本组件只负责摆放。
import { useTranslations } from '@/lib/i18n/client'
import { formatMoney } from '@/lib/format'
import type { CalcResult, CalcLine } from '@/app/pricing/calculator/actions'

export default function PriceBreakdown({
    res,
    negativeNote,
}: {
    res: CalcResult
    // 净值 ≤ 0 时的提示。措辞随场景不同(计价器是"这单不值",化验页是"不会自动定价"),
    // 所以由调用方给,位置固定在抬头行之后。
    negativeNote?: React.ReactNode
}) {
    const t = useTranslations()

    const priceCell = (l: CalcLine) => {
        if (l.price_usd_per_tonne == null) return <span className="text-gray-400">—</span>
        return (
            <>
                <span className="font-mono">{formatMoney(l.price_usd_per_tonne)}</span>
                <span className="text-gray-500 text-xs ml-2">
                    {l.price_date ?? (l.price_from ? `${l.price_from} – ${l.price_to}` : '')}
                </span>
            </>
        )
    }

    return (
        <div>
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

            {negativeNote}

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

            <div className="overflow-x-auto">
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
                                    {formatMoney(l.metal_value_usd)}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>

            <div className="mt-4 max-w-md ml-auto text-sm space-y-1">
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.grossValue')}</span>
                    <span className="font-mono">{formatMoney(res.gross_value_usd)}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.treatmentCharge')}</span>
                    <span className="font-mono">−{formatMoney(res.treatment_usd)}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('pricing.discountAmount')}</span>
                    <span className="font-mono">−{formatMoney(res.discount_usd)}</span>
                </div>
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('pricing.netValue')}</span>
                    <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                        {formatMoney(res.net_value_usd)}
                    </span>
                </div>
                <div className="flex justify-between font-bold">
                    <span>{t('pricing.unitPrice')}</span>
                    <span className={'font-mono ' + (res.negative_value ? 'text-red-600' : '')}>
                        {res.unit_price_usd_per_kg}
                    </span>
                </div>
            </div>
        </div>
    )
}
