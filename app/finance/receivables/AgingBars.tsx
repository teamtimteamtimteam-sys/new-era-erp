// app/finance/receivables/AgingBars.tsx — 应收账龄的横条图(CHART-1 ④ · B1)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【零新查询】四个桶的金额【已经在页面手里了】(`report.buckets`,读自
// ar_aging_asof(as_of))。本组件只是把已经印成四个数字的东西再画一次长度 ——
// 它不发查询、不算账。**本页不算账**那条规矩(OPS-16)在这里原样成立。
//
// 【出处三格,逐一说明它从哪来】
//   · 期间   = 截至日(report.as_of)。账龄是【截至某一天】的,不是一段区间。
//   · 来源   = ar_aging_asof(as_of) —— 写函数名,不写"数据库"。
//   · 暂定   = 两件事之一为真时才说:金额口径不是最终的(amount_basis),
//              或者有未计价的单据被排除在外(unpriced_excluded)。
//              **那两个字段本来就在报表里,这里不是新发明一个判断**,
//              是把页面上已经用 AgingAsOfNotice 说过的话,再对这张图说一次 ——
//              因为一张图会被单独截屏,而截屏会把旁边那段说明留在原地。
//
// 【空态】四个桶全是零 ⇒ 没有未结应收。**那不是"没有记录"**,它是一个
// 有意义的、真实的零 —— 所以这里【不】走 no-rows,而是照画四根零长的条,
// 旁边印着 0.00。把它说成"还没有记录"会是一句假话。
// 真正的 no-rows(一张未结单据都没有)与它在数字上一样,在含义上一样 ——
// 所以这张图【没有空态分支】,而这一句是解释,不是遗漏。
// ════════════════════════════════════════════════════════════════════════════
import ChartCard from '@/app/components/charts/ChartCard'
import BarRows from '@/app/components/charts/BarRows'
import { BUCKETS } from '../agingBuckets'
import type { AmountBasis } from '../agingAsOf'
import { getTranslations } from '@/lib/i18n/server'

export default async function AgingBars({
    buckets, labels, fmt, title, asOf, amountBasis, unpricedExcluded,
}: {
    buckets: Record<string, number>
    labels: Record<string, string>
    fmt: (v: number) => string
    title: string
    asOf: string
    amountBasis: AmountBasis
    unpricedExcluded: number | null
}) {
    const t = await getTranslations()

    const values = BUCKETS.map((b) => buckets[b] ?? 0)
    // 【分母是四桶之和】—— 不是未结合计。见调用点的注释。
    const sum = values.reduce((a, b) => a + b, 0)

    const rows = BUCKETS.map((b, i) => ({
        label: labels[b],
        value: values[i],
        display: fmt(values[i]),
        // 【整张图只强调一根】90+ 是唯一一根要被指出来的 —— 与上面汇总条里
        // 那个 text-red-600 说的是同一件事,不是新增一个判断。
        emphasis: b === 'b90_plus',
    }))

    // ★【"暂定"要用【已有的那两句话】,不要新写一句】★
    // 措辞的真源是 finance.agingAsOf.basis.<token> 与 .unpricedExcluded ——
    // AgingAsOfNotice 用的就是它们。新写一句会造出同一件事的第二份说法,
    // 而两份说法必然漂开(本仓库为这个形状付过账,见 AGENTS.md 的预览规则)。
    //
    // 【哪一种口径【才算】暂定 —— 这是一个判断,写出来以便反驳】
    //   · quantity_now_price_asof：单价按截至日【重建】、数量取【此刻】的
    //     —— 两个时点混在一个数里,**它是暂定的**。
    //   · amounts_as_recorded：金额就是单据上记着的,开出来之后不再变
    //     —— **它是最终的**,把它标成暂定是反方向的假话。
    const provisional: string[] = []
    if (amountBasis === 'quantity_now_price_asof') {
        provisional.push(t('finance.agingAsOf.basis.' + amountBasis))
    }
    if (unpricedExcluded !== null && unpricedExcluded > 0) {
        provisional.push(t('finance.agingAsOf.unpricedExcluded', { n: String(unpricedExcluded) }))
    }

    return (
        <ChartCard
            title={title}
            basis={{
                period: t('charts.period.asAt', { date: asOf }),
                // CONV-0 ②c:此前这里印的是 `ar_aging_asof(as_of)` —— 一个函数名。
                // 真源仍然记在本文件抬头的【出处三格】那一段里，给改这张图的人看。
                source: t('charts.shows.arAging'),
                provisional: provisional.length ? provisional.join(' · ') : null,
            }}
            state={{ kind: 'ok' }}
            footnote={t('finance.agingChartNote')}
        >
            <BarRows rows={rows} max={sum} />
        </ChartCard>
    )
}
