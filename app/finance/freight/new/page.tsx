// app/finance/freight/new/page.tsx
// 录一张运费单(服务端壳):取货代候选 + 可分摊的在册进料批次。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency, getCurrencyCodes } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import NewFreightForm, { type BatchOption } from './NewFreightForm'
import Subnav from '../../Subnav'
import { requireEditPermission } from '@/app/components/moduleGuard'

export default async function NewFreightPage() {
    // 【写页面按 module.finance.edit 把关】—— 与 metal_prices 那四页同一条规矩:
    // 守卫跟着数据自己的 RLS 走,而 freight_documents 的写策略就是这个码。
    const denied = await requireEditPermission('module.finance.edit', 'finance.subnav.freight')
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const currencies = await getCurrencyCodes()

    const suppliers = mustRows(
        // LOG-1b:【反向过滤】运费的收款方只能是货代。这一处与其它十一处方向相反,
        // 所以它单独写在这里,而不是复用那条排除条件。
        //
        // ── FRT-FIX(2026-08-20):这里【曾经还有一句 .eq('status','active')】────
        // 它来自 FRT-1,那时这个下拉列的是【全部供应商】,滤掉未启用的是合理的。
        // LOG-1b 把它收窄成"只列货代"之后,那一句就成了遗留物 —— 而它是致命的:
        //   * suppliers.status 的默认值就是 'draft'(db/tables/suppliers.sql:38),
        //     走完 draft → pending_review → approved → active 要四步;
        //   * 线上唯一一家真货代 BDP 建于 2026-08-19 22:29,至今是 draft;
        //   * 于是这个下拉【自建成起就没有真的列出过任何人】,而页面还说"还没有货代"。
        // 全仓十一个读 suppliers 的下拉,【没有第二个】过滤 status —— 只有这里。
        // 所以删掉它是回到房里的写法,不是放宽一条规则。
        await supabase.from('suppliers').select('id, code, legal_name')
            .is('deleted_at', null)
            .eq('counterparty_type', 'forwarder').order('legal_name'),
        'suppliers'
    ) as { id: string; code: string; legal_name: string }[]

    // 可分摊的批次:在册的进料批。【已被消耗的也要在列】—— 迟到的运费是主路径,
    // 那批货很可能早就加工完卖掉了,不列出来就等于把主路径关在门外。
    const batches = mustRows(
        await supabase.from('inbound_batches_masked')
            .select('id, code, quantity, unit, remaining_qty, unit_price, arrival_date')
            .is('deleted_at', null)
            .order('arrival_date', { ascending: false, nullsFirst: false })
            .limit(200),
        'inbound_batches_masked'
    ) as unknown as BatchOption[]

    // LOG-4b:出境单据可以【可选地】指向一个箱子。只列在册的(未软删)——
    // record_export_freight_document 对已软删的箱子按名拒,所以把它们摆进下拉
    // 就是给人一个注定被拒的选项(AGENTS.md:服务端必然拒绝的动作不该有可提交的控件)。
    // 【航段标签在 JS 里拼,不用嵌套 select】lanes 有两条指向 ports 的外键,
    // PostgREST 的消歧写法要靠约束名 —— 而 app/logistics/containers/page.tsx
    // 早就用的是这条路。同一件事只该有一种做法。
    const containers = mustRows(
        await supabase.from('containers')
            .select('id, code, departure_date, lane_id')
            .is('deleted_at', null)
            .order('departure_date', { ascending: false })
            .limit(200),
        'containers'
    ) as unknown as { id: string; code: string; departure_date: string; lane_id: string | null }[]
    const lanes = mustRows(
        await supabase.from('lanes').select('id, origin_port_id, destination_port_id').is('deleted_at', null),
        'lanes'
    )
    const ports = mustRows(
        await supabase.from('ports').select('id, code').is('deleted_at', null),
        'ports'
    )
    const portCode = new Map(ports.map((p) => [p.id as string, p.code as string]))
    const laneLabel = (laneId: string | null) => {
        if (!laneId) return null
        const l = lanes.find((x) => x.id === laneId)
        if (!l) return null
        const a = portCode.get(l.origin_port_id as string)
        const b = portCode.get(l.destination_port_id as string)
        return a && b ? `${a} → ${b}` : null
    }

    return (
        <div className="p-8">
            <Subnav />
            <NewFreightForm
                suppliers={suppliers}
                batches={batches}
                currencies={currencies}
                baseCurrency={baseCurrency}
                containers={containers.map((c) => ({
                    id: c.id,
                    code: c.code,
                    // 【箱号 + 航段】—— 一个只有 CTR- 号的下拉,人分不出哪个是哪个
                    lane: laneLabel(c.lane_id),
                    departure_date: c.departure_date,
                }))}
            />
        </div>
    )
}
