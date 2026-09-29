// app/components/trail/AuditTrail.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a · 一页底部的"Audit trail"(Tim 的 Q2–Q6 · Q27 · Q29)—— 服务端取数,造好句子再交给版式
// ════════════════════════════════════════════════════════════════════════════
// 【读法】record_trail(主语, id, 条数)—— 页面只说主语,不说表名(Q5)。拒绝是【具名的】:
//   TRAIL_NOT_PERMITTED / TRAIL_SUBJECT_UNKNOWN 在这一段里画成一句拒绝(一枚 Restricted 的意思),
//   【不是】一段空的审计记录 —— 空列表读起来是"什么都没发生过"。别的错误一律抛出(mustRows 同一条:失败不是空集)。
// 【英文专用】整段(标题、列头、每一句)都是英文,界面是中文时也一样(Q7)。
// 【分页】先 20 条;"Show older entries"把 ?trail= 加 20,整页重画并落回这一段(Q29)。
// 【数据只到服务端为止】给客户端的是造好的句子(Entry[]),不是原始行 —— 表名、主键、影像不进页面负载。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { Refusal } from '@/app/components/ui/refusal'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { trailDict, TRAIL_LOG_BEGAN_AT } from '@/lib/trail/dict'
import { buildEntries, fill, fromRecordTrail, type Json } from '@/lib/trail/render'
import { formatTrailStamp } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import AuditTrailList, { OlderEntriesLink } from './AuditTrailList'

export type TrailSubject = 'purchase_order' | 'processing_run' | 'role'

/** 主语的根表 —— 只用来从根行的"今天的样子"里取币种;与 db/functions/trail_subjects.sql 同一份(check-trail-wording 比对)。 */
export const TRAIL_SUBJECT_ROOTS: Record<TrailSubject, string> = {
    purchase_order: 'purchase_orders',
    processing_run: 'processing_runs',
    role: 'roles',
}

const PAGE = 20

/** 页面把 searchParams.trail 交进来;不合法的一律当 20 */
export function trailCount(raw: string | string[] | undefined): number {
    const n = Number(Array.isArray(raw) ? raw[0] : raw)
    return Number.isInteger(n) && n >= PAGE && n <= 500 ? n : PAGE
}

export default async function AuditTrail({ subject, id, show }: { subject: TrailSubject; id: string; show: number }) {
    const supabase = await createClient()
    const res = await supabase.rpc('record_trail', { p_subject: subject, p_id: id, p_entries: show })
    const heading = (
        <>
            <h2 className="mb-1">{TRAIL_TEXT['section.title']}</h2>
            <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['section.intro']}</p>
        </>
    )
    if (res.error) {
        const code = res.error.message.split('|')[0]
        if (code === 'TRAIL_NOT_PERMITTED' || code === 'TRAIL_SUBJECT_UNKNOWN') {
            return (
                <section id="audit-trail" data-audit-trail="refused" className="mt-8 border-t pt-6">
                    {heading}
                    <p className="text-sm">
                        <Refusal>{TRAIL_TEXT.restricted}</Refusal>{' '}
                        {TRAIL_TEXT[code === 'TRAIL_NOT_PERMITTED' ? 'refusal.notPermitted' : 'refusal.unknown']}
                    </p>
                </section>
            )
        }
        throw new Error(`record_trail(${subject}) failed: ${res.error.message}`)
    }
    // 两种具名拒绝上面已经接住;走到这里的只能是成功(mustRows 对别的错误照样抛)
    const rows = mustRows(res, `record_trail(${subject})`)
    const dict = trailDict(await getBaseCurrency())
    const root = rows.find((r) => r.table_name === TRAIL_SUBJECT_ROOTS[subject] && r.ctx)
    const ctx = (root?.ctx ?? null) as { currency?: Json } | null
    const currency = typeof ctx?.currency === 'string' ? ctx.currency : null
    const entries = buildEntries(dict, rows.map((r) => fromRecordTrail(r as Parameters<typeof fromRecordTrail>[0])), { currency })
    const more = rows.some((r) => r.more)
    return (
        <section id="audit-trail" data-audit-trail={entries.length ? 'entries' : 'empty'} className="mt-8 border-t pt-6">
            {heading}
            {entries.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{TRAIL_TEXT.noEntries}</p>
            ) : (
                <AuditTrailList entries={entries} divider={fill(TRAIL_TEXT.divider, { date: formatTrailStamp(TRAIL_LOG_BEGAN_AT) })} />
            )}
            {more && <OlderEntriesLink href={`?trail=${show + PAGE}#audit-trail`} />}
        </section>
    )
}
