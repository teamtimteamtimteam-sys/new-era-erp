// app/operation/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-6 ⑨(2026-09-04)· 运营 Overview —— 【替掉】那张子页面卡片墙
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么】NAV-CLEANUP-1 ③ 建的 <ModuleLanding>:把运营名下的二级条目
//   原样画成一排卡片。**Tim 的裁定:绝对不能是模块内子页面的卡片排列。**
//   理由是形状的来源,原样抄在这里:/tools/pricing 是卡片排列而那是【对的】——
//   它是一张二级页,职责就是把三个孩子递出来。**一级模块不同:它的二级菜单
//   已经把每一页列了一遍**,Overview 再用卡片复述一次就是第三遍。
//   完整论证:docs/module-overview-basis.md。
//
// ★【判据只有一条,而 <Figure> 的 spans 那一格【执行】它】★
//   一个事实能上这一页,当且仅当它横跨若干张子页面、而其中任何一张自己都
//   说不出来。填不出 spans = 某一页自己就答得了 = 它不属于这里。
//
// 【本页两条,而【两条】本身是判断的一部分】
//   ① 计划与实际的差距 —— 工单在 /operation/orders,实际投入产出在
//      /operation/processing;work_order_fulfilment 是把这两侧对起来的那一份,
//      **而没有任何一张页面印着"有几条超阈"。**
//   ② 在制占产出的比例 —— /output 列出全部产出批次却不说它们还等哪一道;
//      /operation/wip 列出等着的那些却不说它占多少。**比例两页都说不出。**
//
// ★【本刀【没有】把 work_order_variance_beyond 这一支从提醒页搬过来 —— 说清楚】★
//   docs/module-overview-basis.md §6 给它定的返回条件是「建运营 Overview 的
//   那一刀,把对应那一支一起搬过去」。**本刀没有做,而这是一个有意识的取舍,
//   不是遗漏**:搬一支要动 operations_now(一次视图迁移)+ fixture 111 的
//   v_expected + i18n 的后缀集合,而本刀已经带着一支删表的迁移。
//   ★ 所以本页 ① 【刻意】不是那一支的复制品 ★:那一支说的是「这一炉超阈了,
//     去看看」(一件带主语的待办),本页说的是「有计划的工单条目里有几条超阈、
//     最大偏到多少」(一个模块状态)。**粒度与主语都不同,不构成两份实现。**
//   完整的返回条件与代价记在本刀报告与那份文件里。
//
// 【成本】两次查询都落在【专程打开的】模块页上,不是首页 —— operations_now 那条
//   「无界扫描由每个用户每次访问买单」的界限之所以严,正因为它长在首页上。
//   两支都带 limit / 聚合,没有无界扫描。
//
// 【手机(390px)】单列 max-w-3xl · p-4 sm:p-8,与 CONV-7 那两页逐字相同。
//   一条陈述是纵向堆叠:标题 → 话 → 三行出处;出处 text-xs leading-5 自动换行,
//   **刻意不折叠**(一个要点开才看得见的基准等于没有基准)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN, allows } from '@/lib/modules'
import { getMyPermissions } from '@/lib/permissions'
import { mustRows } from '@/lib/db-helpers'
import { businessToday } from '@/lib/format'
import Figure from '@/app/components/overview/Figure'

type Fulfilment = {
    work_order_id: string
    work_order_code: string
    side: string
    material_code: string | null
    planned_or_expected_qty: number | null
    actual_qty: number | null
    variance_qty: number | null
    has_plan: boolean
}
type WipRow = { output_batch_id: string; remaining_qty: number | null; output_date: string | null }

export default async function OperationOverviewPage() {
    // OPS-15:进不去的页面要【说出来】。放在任何查询之前 —— 拒绝必须是权限答复,
    // 不能是从空结果倒推。
    const denied = await requireFunction(FN.operationHome)
    if (denied) return denied

    const t = await getTranslations()
    const perms = await getMyPermissions()
    const supabase = await createClient()
    const asOf = businessToday()

    // ★【先判权限,再决定查不查】★(module-overview-basis §4-5)
    //   从空结果倒推"你没权限"是 OPS-14/15 那条老病,而在【属主权限视图】上
    //   它还多错一层:无权读者拿到的是空集,与"真的一条都没有"长得一模一样。
    //   本页两支的门恰好【都是】进这一页的那个码(module.processing.view),
    //   所以这里不会出现 D5 —— **而这句话是查过的,不是假设的**:
    //   processing_wip 与 work_order_fulfilment 两张视图体内的谓词都是它。
    //   ★ 产出总数那一半用的是 output_batches,它的码【不同】(module.output.view)★
    //     实测 live 授权:进得来这一页的四个角色(admin·auditor·gm·operations)
    //     恰好都持有 module.output.view,所以今天没有人看见那一格的「受限」——
    //     **但判断仍然由权限做,不由值做**,否则哪天授权一改,一个无权的人
    //     会读到"产出批次 0 条"这句谎。
    const canReadOutput = allows('module.output.view', perms)

    const [fulRes, wipRes, outRes] = await Promise.all([
        supabase
            .from('work_order_fulfilment')
            .select('work_order_id, work_order_code, side, material_code, planned_or_expected_qty, actual_qty, variance_qty, has_plan')
            .eq('has_plan', true),
        supabase.from('processing_wip').select('output_batch_id, remaining_qty, output_date'),
        canReadOutput
            ? supabase.from('output_batches').select('id', { count: 'exact', head: true }).is('deleted_at', null)
            : Promise.resolve({ data: null, error: null, count: null }),
    ])

    // 【每一次查询过 mustRows】—— 失败必须是失败。旧的 /hr 用的是 `?? []`:
    // 一次 RLS 拒绝会渲染成「0 人在职」。
    const ful = mustRows(fulRes, 'work_order_fulfilment') as unknown as Fulfilment[]
    const wip = mustRows(wipRes, 'processing_wip') as unknown as WipRow[]
    if (canReadOutput && outRes.error) {
        throw new Error(`查询失败(output_batches): ${outRes.error.message}`)
    }
    const outputTotal = canReadOutput ? (outRes.count ?? 0) : null

    // ── ① 计划与实际 ────────────────────────────────────────────────────────
    // 【超阈的判据【不在这一页上】】阈值住在 processing_settings,而
    // operations_now 那一支已经按它算过。本页【不复制那个阈值】—— 复制它就是
    // 第二份实现,而两份实现迟早各错一次(本仓库 §一 的老账)。
    // 所以这里说的是【偏差本身】:有计划的条目里,实际与计划不一致的有几条、
    // 最大偏到多少。**它不冒充那条阈值判断。**
    const offPlan = ful.filter((r) => Number(r.variance_qty ?? 0) !== 0)
    const worst = offPlan.reduce<Fulfilment | null>(
        (a, r) => (a === null || Math.abs(Number(r.variance_qty)) > Math.abs(Number(a.variance_qty)) ? r : a),
        null,
    )

    // ── ② 在制占产出的比例 ──────────────────────────────────────────────────
    const wipQty = wip.reduce((s, r) => s + Number(r.remaining_qty ?? 0), 0)
    const oldest = wip
        .map((r) => r.output_date)
        .filter((d): d is string => Boolean(d))
        .sort()[0] ?? null
    const oldestDays = oldest
        ? Math.max(0, Math.round((Date.parse(asOf) - Date.parse(oldest)) / 86_400_000))
        : null

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.operation')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 计划与实际 ───────────────────────────────────────────── */}
            <Figure
                title={t('operationOverview.planTitle')}
                basis={{
                    asOf,
                    source: t('operationOverview.planSource'),
                    spans: t('operationOverview.planSpans'),
                }}
                state={
                    // ★【答不上来 ≠ 是零】★ 一条带计划的工单都没有,就【没有】这个比
                    // ——不是"零条偏离"。CHART-1 的裁定在这里的样子:依据不够就拒绝答。
                    ful.length === 0
                        ? { kind: 'unanswerable', why: t('operationOverview.planNoPlans') }
                        : { kind: 'ok' }
                }
                action={
                    <Link href="/operation/orders" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('processing.subnav.workOrders')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('operationOverview.planLine', { off: offPlan.length, total: ful.length })}
                </p>
                {worst && (
                    <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('operationOverview.planWorst', {
                            code: worst.work_order_code,
                            material: worst.material_code ?? '—',
                            side: t('operationOverview.side.' + worst.side),
                            planned: String(worst.planned_or_expected_qty ?? '—'),
                            actual: String(worst.actual_qty ?? '—'),
                        })}
                    </p>
                )}
            </Figure>

            {/* ── ② 在制占产出的比例 ─────────────────────────────────────── */}
            <Figure
                title={t('operationOverview.wipTitle')}
                basis={{
                    asOf,
                    source: t('operationOverview.wipSource'),
                    spans: t('operationOverview.wipSpans'),
                }}
                state={
                    // 【受限画成【具名的】限制(D5),不是空白、更不是零】
                    !canReadOutput
                        ? { kind: 'restricted', permission: 'module.output.view' }
                        : outputTotal === 0
                          ? { kind: 'unanswerable', why: t('operationOverview.wipNoOutput') }
                          : { kind: 'ok' }
                }
                action={
                    <Link href="/operation/wip" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
                        {t('processing.subnav.wip')}
                    </Link>
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('operationOverview.wipLine', {
                        wip: wip.length,
                        total: outputTotal ?? 0,
                        qty: wipQty.toFixed(3).replace(/\.?0+$/, ''),
                    })}
                </p>
                {oldestDays !== null && (
                    <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('operationOverview.wipOldest', { days: oldestDays, date: oldest ?? '—' })}
                    </p>
                )}
            </Figure>
        </div>
    )
}
