'use client'

// "如果应用"的完整预览:计价明细(与计价器同一组件)+ 对当前价格的影响对比。
// 录入页(实时)与详情页(未应用时,服务端一次算好)共用这一块 —— 两处看到的
// 是同一份东西。所有数字都是算好后传进来的,组件本身不做算术。
import { useTranslations } from '@/lib/i18n/client'
import { formatMoneyBare, formatUnitCost } from '@/lib/format'
import PriceBreakdown from '@/app/components/pricing/PriceBreakdown'
import type { CalcResult } from '@/app/tools/pricing/calculator/actions'
import type { AssayImpact } from './actions'

export default function AssayImpactPreview({
    res,
    impact,
    baseCurrency,
}: {
    res: CalcResult
    // 净值 ≤ 0 时没有影响数字 —— 那种料 apply_assay_result 本来就不会给它定价,
    // 摆一个"调整 −X 元"的对比块是误导。计价明细照常显示。
    impact?: AssayImpact
    // ASY-3:本位币来自 currencies.is_base(页面 getBaseCurrency 后传进来),
    // 不是常量 —— 面板【在这里换单位】,上半截是行情口径的 USD,这一块是本位币。
    baseCurrency: string
}) {
    const t = useTranslations()

    return (
        <>
            <PriceBreakdown res={res} />
            {impact && (
            <div className="mt-4 bg-gray-50 rounded p-4 text-sm max-w-md ml-auto space-y-1">
                {/* 【分界线】:换单位的地方要说出来,还要说清是怎么换的。
                    ASY-1 之前这一块与上面的 USD 明细无缝相接、毫无标记 ——
                    6.34/kg 与 8.1152/kg 隔三行,读者无从知道单位变了。 */}
                <p className="text-xs text-gray-500 border-b pb-2 mb-2">
                    {impact.fx_rate === null || impact.rate_as_of === null
                        ? t('assay.impactInBase', { ccy: baseCurrency })
                        : t('assay.impactInBaseAt', {
                              ccy: baseCurrency,
                              rate: impact.fx_rate,
                              date: impact.rate_as_of,
                          })}
                </p>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.currentPrice', { ccy: baseCurrency })}</span>
                    <span className="font-mono">
                        {impact.current_unit_price === null ? '—' : formatUnitCost(impact.current_unit_price)}
                    </span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.newPrice', { ccy: baseCurrency })}</span>
                    <span className="font-mono font-medium">{formatUnitCost(impact.new_unit_price)}</span>
                </div>
                <div className="flex justify-between">
                    <span className="text-gray-600">{t('assay.priceDelta', { ccy: baseCurrency })}</span>
                    <span className="font-mono">{formatUnitCost(impact.unit_delta)}</span>
                </div>
                <div className="flex justify-between border-t pt-1 font-bold">
                    <span>{t('assay.totalDelta', { ccy: baseCurrency })}</span>
                    <span className="font-mono">{formatMoneyBare(impact.total_delta, '同行左侧的行标签「调整总额({ccy})」+ 本块抬头那句"以下为本位币 {ccy}"')}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                    <span>
                        {t('assay.inventoryShare', { ccy: baseCurrency })}
                        <span className="text-gray-400 ml-1">({Math.round(impact.in_stock_ratio * 100)}%)</span>
                    </span>
                    <span className="font-mono">{formatMoneyBare(impact.inventory_share, '同行左侧的行标签「计入存货({ccy})」')}</span>
                </div>
                <div className="flex justify-between text-gray-600">
                    <span>{t('assay.costShare', { ccy: baseCurrency })}</span>
                    <span className="font-mono">{formatMoneyBare(impact.cost_share, '同行左侧的行标签「计入销售成本({ccy})」')}</span>
                </div>
            </div>
            )}
        </>
    )
}
