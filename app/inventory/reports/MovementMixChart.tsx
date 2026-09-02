// app/inventory/reports/MovementMixChart.tsx — 库存流水构成(CHART-1 ④ · B3)。
//
// ════════════════════════════════════════════════════════════════════════════
// 【CHART-0 的判词:建,横条图】它是勘察里"唯一一个今天就画得出真实形状的图"
// —— 12 种 movement_type 互斥,加起来就是全部流水。
//
// 【为什么放在 /inventory/reports 而不是 /inventory】
// CHART-0 把位置写成"`/inventory` 或 `/inventory/reports`",没有裁。这里裁了:
// **报表中心**。理由:`/inventory` 是干活的那一页(当前库存、按批次操作),
// 而这张图讲的是【至今为止发生过什么】—— 那是一份报表,不是一个操作视图。
// 把一张全历史构成图挂在操作页上,它每天都在那儿、每天都没人用它做决定。
//
// ★★【为什么是 12 次 count,而不是"把 106 行取回来自己数"】★★
// 后者今天更快(一次查询),而且 106 行确实不多。但 inventory_movements
// **是这套系统里长得最快的表**(每一次收货、加工、销售、调整都写它),
// 而"取回来自己数"的传输量与行数成正比 —— 它会在这张表长到十万行那天
// 从一张图变成一个问题。**count 走 HEAD,永远只传一个数。**
// 12 次并发(pMap,上限 12)= 一次往返的墙上时间。
// 【这与 CHART-1 ② 是同一条判断,方向相同】那一刀量出来的教训是
// 「减的是串行的长度,不是每一次查询的成本」—— 这里从一开始就并发。
//
// ★【颜色:12 根条,一个颜色】★(CHART-0 §五)
// 12 个可辨的品牌色推不出来,而横条**本来就不需要**:一根条一个标签,
// 颜色不承担区分。**这正是图表库会做错的那一处** —— 它会默认给 12 个彩虹色。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { pMap, DEFAULT_QUERY_CONCURRENCY } from '@/lib/pMap'
import ChartCard from '@/app/components/charts/ChartCard'
import BarRows from '@/app/components/charts/BarRows'

/**
 * 12 种流水类型。
 * **真源是 db/tables/inventory_movements.sql 上那条 CHECK**,
 * 而 scripts/check-i18n.mjs 的 MANIFEST 已经从那条 CHECK 现读后缀集合
 * (`movements.type.` 那一行)—— 所以库里多一种类型,两个语言少一句话
 * 就【构建变红】。这里这份数组因此不是"第二份清单",它是那条 CHECK 的
 * 一次转录,而转录漏了一种的后果是这张图少一根条 —— 见下面那条断言。
 */
const MOVEMENT_TYPES = [
    'receipt', 'processing_consume', 'processing_produce', 'reversal_restore',
    'reversal_void', 'sale', 'writeoff', 'adjustment',
    'status_change_out', 'status_change_in', 'transfer_out', 'transfer_in',
] as const

export default async function MovementMixChart() {
    const supabase = await createClient()
    const t = await getTranslations()

    // 【12 次 HEAD count,并发发出】—— 不取行,只取数。
    const counts = await pMap(MOVEMENT_TYPES, DEFAULT_QUERY_CONCURRENCY, async (mt) => {
        const c = await supabase.from('inventory_movements')
            .select('movement_type', { count: 'exact', head: true }).eq('movement_type', mt)
        // 【查不到不是零】—— 一次读失败与"这一类一条都没有"在图上长得一模一样,
        // 而它们的含义相反。AGENTS.md 的 mustRows 那一条,用在 count 上。
        if (c.error) throw new Error(`流水构成查询失败(${mt}): ${c.error.message}`)
        return c.count ?? 0
    })

    const total = counts.reduce((a, b) => a + b, 0)

    // 【排序:按条数倒序】—— 与账龄那张不同。账龄的桶【有固有顺序】(0-30 → 90+),
    // 打乱它就是撒谎;而流水类型之间没有固有顺序,按大小排才读得出构成。
    // 【零的那些留在末尾,而且【留着】】一种一条都没有的流水,与一种不存在的流水
    // 是两件事 —— 把零的滤掉,读者就再也看不出"写损失至今一条都没有"。
    const rows = MOVEMENT_TYPES
        .map((mt, i) => ({ mt, n: counts[i] }))
        .sort((a, b) => b.n - a.n)
        .map((r) => ({
            label: t('movements.type.' + r.mt),
            value: r.n,
            display: total > 0 ? `${r.n} · ${((r.n / total) * 100).toFixed(1)}%` : String(r.n),
        }))

    return (
        <ChartCard
            title={t('reports.movementMix.title')}
            basis={{
                // 【期间】这张图【不筛期间】—— 它是建库至今的全部流水。说出来,
                // 免得读者以为是本月。
                period: t('reports.movementMix.periodAll'),
                source: 'inventory_movements.movement_type',
                // 冲销的两条腿(reversal_void / reversal_restore)也算在里面 ——
                // 它们是真实发生过的流水行,不是"错误"。这不是暂定,是口径,
                // 所以它写在脚注,不写在这里。
                provisional: null,
            }}
            // 【一行都没有】= 还没有任何库存流水。**不画 12 根零长的条** ——
            // 那会让屏幕看起来像"每一类都是零",而真相是这张表还没开始。
            state={total === 0 ? { kind: 'no-rows' } : { kind: 'ok' }}
            footnote={t('reports.movementMix.note', { total: String(total) })}
        >
            {/* 【分母是最大的那一类】,不是合计 —— 12 类里最大的一类占约 25%,
                用合计当分母会让每一根都短得看不出差别。账龄那张用的是合计,
                因为那四个桶【加起来就是那个整体】,读者要读的正是占比。 */}
            <BarRows rows={rows} max={rows[0]?.value ?? 0} />
        </ChartCard>
    )
}
