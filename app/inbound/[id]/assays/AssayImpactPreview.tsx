'use client'

// "如果应用"的完整预览:计价明细(与计价器同一组件)+ 对当前价格的影响对比。
// 录入页(实时)与详情页(未应用时,服务端一次算好)共用这一块 —— 两处看到的
// 是同一份东西。所有数字都是算好后传进来的,组件本身不做算术。
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd, formatUnitCost } from '@/lib/format'
import PriceBreakdown from '@/app/components/pricing/PriceBreakdown'
import type { CalcResult } from '@/app/pricing/calculator/actions'
import type { AssayImpact } from './actions'

export default function AssayImpactPreview({
    res,
    impact,
}: {
    res: CalcResult
    // 净值 ≤ 0 时没有影响数字 —— 那种料 apply_assay_result 本来就不会给它定价,
    // 摆一个"调整 −X 元"的对比块是误导。计价明细照常显示。
    impact?: AssayImpact
}) {
    const t = useTranslations()

    return (
        <>
            <PriceBreakdown res={res} />
            {impact && (
            <div className="mt-4 bg-gray-50 rounded p-4 text-sm max-w-md ml-auto space-y-1">
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.currentPrice')}</span>
                    <span className="font-mono">
                        {impact.current_unit_price === null ? '—' : formatUnitCost(impact.current_unit_price)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.newPrice')}</span>
                    <span className="font-mono font-medium">{formatUnitCost(impact.new_unit_price)}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.priceDelta')}</span>
                    <span className="font-mono">{formatUnitCost(impact.unit_delta)}</span>
                </div>
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('assay.totalDelta')}</span>
                    <span className="font-mono">{formatUsd(impact.total_delta)}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                    <span>
                        {t('assay.inventoryShare')}
                        <span className="text-gray-400 ml-1">({Math.round(impact.in_stock_ratio * 100)}%)</span>
                    </span>
                    <span className="font-mono">{formatUsd(impact.inventory_share)}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                    <span>{t('assay.costShare')}</span>
                    <span className="font-mono">{formatUsd(impact.cost_share)}</span>
                </div>
            </div>
            )}
        </>
    )
}
