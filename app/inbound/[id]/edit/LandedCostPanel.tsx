'use client'

// PROC-COST-1:落地成本拆解 —— 采购价 / 运费 / 加工成本 / 合计。
//
// 【为什么这块面板要存在】此前这三个组件里,只有采购价在屏幕上。运费(FRT-1)
// 与加工成本(PROC-COST-1)都资本化进了批次,而全库【唯一】读它们的地方是
// allocate_processing_costs 的材料成本表达式 —— 也就是说它们只对函数可见,
// 对人不可见。本刀的验收条件正是"操作员能在屏幕上看见一批货的已资本化加工成本,
// 与它的采购价【分开】",所以这块面板是那条验收条件本身,不是装饰。
// 顺带把运费同样的隐身也一并解决了。
//
// 【为什么不在这里做加法之外的任何事】三个数都由数据库给出:
// 采购价 = quantity × unit_price(与 ap_open_items 同一个算式),
// 运费 = batch_freight_base(),加工成本 = batch_processing_cost_base()。
// 页面【不重新实现】任何一条 —— 那是本仓库付过四次账的那个缺陷(见 AGENTS.md
// "A screen that previews a posting ASKS the database what it will be")。
//
// 【null 不是 0】任何一项读到 null,显示的是「受限」而不是 0.00 —— 后者是谎话。
// batch_processing_cost_base 对无权读者返回 NULL 正是为了让这里分得开。
//
// 【四项【一起】挂在 data.view_prices 上,而这是一个决定,不是顺手】
// 采购价本来就是被遮蔽的价格数据(与本页 PricingPanel 同一道闸)。运费与加工成本
// 【本身】不是供应商报价,单独看没有那么敏感 —— 但**合计减去另外两项就是采购价**。
// 也就是说:放行合计而遮蔽采购价,等于用减法把它泄出去。所以四项同进同出。
// 【界面比服务端严,这是安全的方向】batch_processing_cost_base 对持
// module.inbound.view 的人本来就给真数;这里少给一点,不会说谎,只会说「受限」。

import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { MaskedValue } from '@/app/components/MaskedValue'

export default function LandedCostPanel({
    purchaseBase,
    freightBase,
    processingBase,
    baseCurrency,
    canViewPrices,
}: {
    /** quantity × unit_price;没有定价时为 null(【未定价】,不是 0) */
    purchaseBase: number | null
    freightBase: number | null
    processingBase: number | null
    baseCurrency: string
    canViewPrices: boolean
}) {
    const t = useTranslations()

    // 【合计只在三项都是数时才给】缺一项的合计是一个看起来完整的错数字 ——
    // 而"少算了运费的落地成本"恰恰是那种没人会去核对的数。宁可留白。
    const complete =
        purchaseBase !== null && freightBase !== null && processingBase !== null
    const total = complete
        ? (purchaseBase as number) + (freightBase as number) + (processingBase as number)
        : null

    const Row = ({
        label,
        value,
        hint,
        strong = false,
    }: {
        label: string
        value: number | null
        hint?: string
        strong?: boolean
    }) => (
        <div
            className={`flex items-baseline justify-between gap-4 py-1.5 ${
                strong ? 'border-t border-gray-300 mt-1 pt-2 font-medium' : ''
            }`}
        >
            <span className="text-sm text-gray-700">
                {label}
                {hint ? <span className="ml-2 text-xs text-gray-400">{hint}</span> : null}
            </span>
            <span className="text-sm tabular-nums">
                <MaskedValue
                    value={value}
                    canView={canViewPrices}
                    format={(v) => formatAmount(v as number, baseCurrency)}
                    fallback="—"
                />
            </span>
        </div>
    )

    return (
        <section className="mb-6 rounded border border-gray-200 p-4">
            <h2 className="mb-1 text-base font-medium">{t('inbound.landedCost.title')}</h2>
            {/* 说明这块面板在回答什么 —— 而不是让人从三个数字里猜 */}
            <p className="mb-3 text-xs text-gray-500">{t('inbound.landedCost.blurb')}</p>

            <Row label={t('inbound.landedCost.purchase')} value={purchaseBase} />
            <Row label={t('inbound.landedCost.freight')} value={freightBase} />
            <Row
                label={t('inbound.landedCost.processing')}
                value={processingBase}
                hint={t('inbound.landedCost.processingHint')}
            />
            <Row label={t('inbound.landedCost.total')} value={total} strong />

            {/* 【采购价没定过的时候说出来】—— 合计留白必须有理由,否则它读起来像坏了 */}
            {canViewPrices && purchaseBase === null ? (
                <p className="mt-2 text-xs text-amber-700">{t('inbound.landedCost.notPriced')}</p>
            ) : null}
        </section>
    )
}
