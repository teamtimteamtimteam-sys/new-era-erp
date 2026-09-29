// app/components/trail/RecentTrail.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q12)· /inventory 上仓库申请的那一小块审计记录
// ════════════════════════════════════════════════════════════════════════════
// 【读法与每一页底部同一支】record_trail('warehouse_request', 申请, n)—— 一张申请一次,取库存页那一块已经列出来的
//   那几张(warehouse_requests_visible():在等的全部 + 最近决定 / 撤回的几张),把它们的记录按时刻合起来,新的在前。
//   没有新造第二个读法:同一道门(module.inventory.view 或财务)、同一份逐行读规则、同一步遮蔽 ——
//   仓库的人看得见"谁提的、谁批的",金额按 data.view_prices 给(Q12:没有它就是 Restricted)。
// 【每一条带一栏 Record】那张申请,链到它的主体(批次 / 加工单)的页面 —— 那一页底部有它完整的记录。
// 【英文专用】标题、说明、列头、每一句都来自 lib/trail/text.ts(Q7)。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { trailDict } from '@/lib/trail/dict'
import { buildEntries, fromRecordTrail } from '@/lib/trail/render'
import AuditTrailList, { type ViewEntry } from './AuditTrailList'

const SHOW = 10
const REQUESTS = 5

type Req = { id: string; label: string; inbound_batch_id: string | null; output_batch_id: string | null; run_id: string | null }

function subjectHref(r: Req): string | null {
    if (r.inbound_batch_id) return `/inbound/${r.inbound_batch_id}/edit`
    if (r.output_batch_id) return `/output/${r.output_batch_id}/edit`
    if (r.run_id) return `/operation/processing/${r.run_id}`
    return null
}

export default async function RecentTrail() {
    const supabase = await createClient()
    const reqs = (mustRows(await supabase.rpc('warehouse_requests_visible', { p_recent: REQUESTS }), 'warehouse_requests_visible') as Req[])
        .slice(0, REQUESTS)
    const dict = trailDict(await getBaseCurrency())
    const all: ViewEntry[] = []
    for (const r of reqs) {
        const rows = mustRows(await supabase.rpc('record_trail', { p_subject: 'warehouse_request', p_id: r.id, p_entries: SHOW }),
            `record_trail(warehouse_request ${r.label})`)
        const entries = buildEntries(dict, rows.map((x) => fromRecordTrail(x as Parameters<typeof fromRecordTrail>[0])),
            { subject: 'warehouse_request' })
        for (const e of entries) all.push({ ...e, key: `${r.id}:${e.key}`, recordText: r.label, recordHref: subjectHref(r) })
    }
    all.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0))
    const shown = all.slice(0, SHOW)
    return (
        <section id="warehouse-request-trail" data-audit-trail={shown.length ? 'entries' : 'empty'} className="mt-6">
            <h3 className="mb-1 text-sm font-medium">{TRAIL_TEXT['section.title']}</h3>
            <p className="mb-2 text-xs text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['wrBlock.intro']}</p>
            {shown.length === 0
                ? <p className="text-sm text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['wrBlock.empty']}</p>
                : <AuditTrailList entries={shown} withRecord />}
        </section>
    )
}
