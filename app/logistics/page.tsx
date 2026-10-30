// app/logistics/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// CONV-6 ⑤c + ⑨(2026-09-04)· 物流 Overview —— 【这个模块此前没有根】
// ════════════════════════════════════════════════════════════════════════════
//
// 【它此前是什么:不存在】docs/module-overview-basis.md §6 那张表里写着
//   「**根本没有 app/logistics/page.tsx**」。物流的地址全是 /logistics/{forwarders,
//   lanes,containers},点模块名只会展开菜单(D2),所以这个地址【404】。
//   本刀建了它,内容是 Overview 而不是落地页。
//
// 【两条陈述】
//   ① **箱子停在哪一段** —— 按最新里程碑分布,加上还欠着的单据数。
//      货柜在 /logistics/containers 一行一行地列,航线要求在 /logistics/lanes ——
//      **没有一页说"四只箱子里三只已到港、一只还在海上"。**
//   ② **发运与货柜挂上了没有** —— 一票发运要落到一只箱子上才走得了。
//      发运是销售那侧的东西(销售订单的发货腿),货柜在 /logistics/containers:
//      **"有几票发运还没挂到任何箱子上"两边都说不出。**
//
// ★【货柜那一半由权限分,不由值分】★ `container_overview` 的门写在视图体里。CONV-6 写这一页时它是
//   module.purchasing.view,于是 operations · sales · warehouse 进得来、读不到 —— 本页因此先判码、画具名的「受限」。
//   FIX-2a(2026-09-05)把视图放宽成 purchasing OR logistics;GOLIVE-1 第 6 行(Tim 2026-10-20 d2 #30)收成
//   **module.logistics.view 一个码** —— 与这一页自己的门是同一个码,所以下面那一句今天对每一个进得来的人都成立。
//   它仍然留着:视图的门哪天再变,这一页说的是「受限」,不是「一只箱子都没有」。
//
// 【手机(390px)】单列 max-w-3xl,与 CONV-7 那两页逐字相同。
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
import { readAll } from '@/lib/readAll'

type ContainerRow = {
    id: string
    code: string
    latest_milestone: string | null
    latest_milestone_date: string | null
    documents_pending: number | null
    shipment_count: number | null
}
type ShipmentRow = { id: string; container_id: string | null }

export default async function LogisticsOverviewPage() {
    const denied = await requireFunction(FN.logisticsHome)
    if (denied) return denied

    const t = await getTranslations()
    const perms = await getMyPermissions()
    const supabase = await createClient()
    const asOf = businessToday()

    // ★【先判权限,再决定查不查】★ —— 见抬头。这一行【就是】那条 D5:
    // 没有它,三个角色会拿到一个空集,然后屏幕告诉他们"一只箱子都没有"。
    const canReadContainers = allows('module.logistics.view', perms)

    const [ctrRes, shpRes] = await Promise.all([
        canReadContainers
            ? readAll(() => supabase
                  .from('container_overview')
                  .select('id, code, latest_milestone, latest_milestone_date, documents_pending, shipment_count'), { label: 'container_overview' })
            : Promise.resolve({ data: null, error: null }),
        // 【发运那一半的门是它自己的 RLS】—— shipments 跟着销售/物流的策略走,
        // 这里不替它判;它要是拒绝,mustRows 会【抛】,不会变成"零票"。
        readAll(() => supabase.from('shipments').select('id, container_id'), { label: 'shipments' }),
    ])

    const containers = canReadContainers
        ? (mustRows(ctrRes as never, 'container_overview') as unknown as ContainerRow[])
        : []
    const shipments = mustRows(shpRes, 'shipments') as unknown as ShipmentRow[]

    // ── ① 按最新里程碑分布 ──────────────────────────────────────────────────
    // 【没有里程碑的箱子【单独一格】】—— 把它并进"已订舱"是替它编一个状态。
    const byMilestone = new Map<string, number>()
    for (const c of containers) {
        const k = c.latest_milestone ?? '__none__'
        byMilestone.set(k, (byMilestone.get(k) ?? 0) + 1)
    }
    const docsPending = containers.reduce((s, c) => s + Number(c.documents_pending ?? 0), 0)

    // ── ② 发运挂接 ──────────────────────────────────────────────────────────
    const unattached = shipments.filter((s) => s.container_id === null)

    return (
        <div className="p-4 sm:p-8 max-w-3xl">
            <h1 className="mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.modFull.logistics')}
            </h1>
            <p className="text-sm mb-6 max-w-2xl" style={{ color: 'var(--brand-muted-text)' }}>
                {t('overview.intro')}
            </p>

            {/* ── ① 箱子停在哪一段 ───────────────────────────────────────── */}
            <Figure
                title={t('logisticsOverview.milestoneTitle')}
                basis={{
                    asOf,
                    source: t('logisticsOverview.milestoneSource'),
                    spans: t('logisticsOverview.milestoneSpans'),
                }}
                state={
                    !canReadContainers
                        ? { kind: 'restricted', permission: 'module.logistics.view' }
                        : containers.length === 0
                          ? { kind: 'unanswerable', why: t('logisticsOverview.milestoneNone') }
                          : { kind: 'ok' }
                }
                action={
                    <Link href="/logistics/containers" className="hover:underline app-link">
                        {t('logistics.containersTitle')}
                    </Link>
                }
            >
                <ul className="space-y-1">
                    {[...byMilestone.entries()].map(([k, n]) => (
                        <li key={k} data-milestone={k} className="text-sm" style={{ color: 'var(--brand-text)' }}>
                            {k === '__none__' ? t('logisticsOverview.milestoneNoneYet') : t('logistics.milestoneLabel.' + k)}
                            {' · '}
                            {t('logisticsOverview.milestoneCount', { n })}
                        </li>
                    ))}
                </ul>
                <p className="text-sm mt-2" style={{ color: 'var(--brand-muted-text)' }}>
                    {t('logisticsOverview.docsPending', { n: docsPending })}
                </p>
            </Figure>

            {/* ── ② 发运与货柜挂上了没有 ─────────────────────────────────── */}
            <Figure
                title={t('logisticsOverview.attachTitle')}
                basis={{
                    asOf,
                    source: t('logisticsOverview.attachSource'),
                    spans: t('logisticsOverview.attachSpans'),
                }}
                state={
                    shipments.length === 0
                        ? { kind: 'unanswerable', why: t('logisticsOverview.attachNone') }
                        : { kind: 'ok' }
                }
            >
                <p className="text-sm" style={{ color: 'var(--brand-text)' }}>
                    {t('logisticsOverview.attachLine', {
                        unattached: unattached.length,
                        total: shipments.length,
                    })}
                </p>
                {/* 【全都没挂上时说一句】—— 一个 "3 / 3" 读起来像统计,而它其实是一个状态。 */}
                {shipments.length > 0 && unattached.length === shipments.length && (
                    <p className="text-sm mt-1" style={{ color: 'var(--brand-muted-text)' }}>
                        {t('logisticsOverview.attachAllLoose')}
                    </p>
                )}
            </Figure>
        </div>
    )
}
