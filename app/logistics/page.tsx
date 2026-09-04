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
// ★★【这一页的 D5 是【实测出来的】,而它同时是本刀报出的一条【发现】】★★
//   进得来这一页的是 module.logistics.view =
//     admin·auditor·cfo·finance·gm·operations·procurement·sales·warehouse(九个)。
//   而 `container_overview` 这张视图体内的谓词是 **module.purchasing.view** =
//     admin·auditor·cfo·finance·gm·procurement(六个)。
//   ★ 于是 **operations · sales · warehouse 三个角色进得来这一页,却读不到货柜** ★。
//
//   【为什么这是一条发现,而不是本页的毛病】NAV-REG-1 / R2 给物流铸了它自己的码,
//   并把【八张表】的 SELECT 策略换成了它。**container_overview 这张视图没有跟着换。**
//   本刀【不改那个门】—— 改一个视图的谓词是一次权限改动,它需要 Tim 裁,
//   而这一刀写在委托书里的是"权限码不变"。所以本页做正确的那件事:
//   **由权限分,不由值分** —— 三个角色看到的是【具名的】「受限(module.purchasing.view)」,
//   而不是一句「没有货柜」。后者是一句谎,而且是最难发现的那一种。
//   (详见本刀报告的「只有人走得了的一遍」那一节。)
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
    const canReadContainers = allows('module.purchasing.view', perms)

    const [ctrRes, shpRes] = await Promise.all([
        canReadContainers
            ? supabase
                  .from('container_overview')
                  .select('id, code, latest_milestone, latest_milestone_date, documents_pending, shipment_count')
            : Promise.resolve({ data: null, error: null }),
        // 【发运那一半的门是它自己的 RLS】—— shipments 跟着销售/物流的策略走,
        // 这里不替它判;它要是拒绝,mustRows 会【抛】,不会变成"零票"。
        supabase.from('shipments').select('id, container_id'),
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
            <h1 className="text-2xl font-bold mb-1" style={{ color: 'var(--brand-text)' }}>
                {t('nav.logistics')}
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
                        ? { kind: 'restricted', permission: 'module.purchasing.view' }
                        : containers.length === 0
                          ? { kind: 'unanswerable', why: t('logisticsOverview.milestoneNone') }
                          : { kind: 'ok' }
                }
                action={
                    <Link href="/logistics/containers" className="hover:underline" style={{ color: 'var(--brand-ocean-fill)' }}>
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
