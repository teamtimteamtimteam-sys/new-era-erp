// app/components/trail/ListTrail.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-2(AT-1b Step 0 §1 第 6 条 · Q2)· 只有清单页的记录的审计记录 —— 航段、港口、公司执照
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】这几种记录没有自己的详情页(/logistics/lanes、/purchasing/licences 一页列全部),而 record_trail 一次读一条。
//   所以这一块在清单页底部:清单上的每一条记录各读一次(同一支 record_trail、同一道门、同一份逐行读规则、同一步遮蔽),
//   合起来按时刻排,新的在前,每一条带一栏 Record(那条记录的名字)。【没有新造第二个读法】—— 与 /inventory 那一块
//   (RecentTrail)同一个做法。
// 【已删掉的记录也读】清单只列在用的;一条被删掉的航段、港口、执照,它的"被删掉"正是这一块要说的事 —— 所以调用方把
//   deleted_at 不为空的那几条也交进来。
// 【同一件事只说一次】港口的记录里包含从它出发、到它为止的航段(Step 0 的登记表),于是"建了一条航段"会在航段自己、
//   起运港、目的港三条记录里各出现一次。时刻、人、标题、每一行都相同的只留第一次(航段排在港口前面,所以留下的是航段那一条)。
// 【分界线】"记录开始之前"的那几条按时刻本来就排在最后(它们都早于分界),分界线画在第一条上方,与每一页底部同一句。
// 【分页】与每一页底部同一个:先 20 条,"Show older entries"把 ?trail= 加 20(每条记录各读那么多,合起来再截)。
// 【英文专用】标题、说明、列头、每一句都来自 lib/trail/text.ts(Q7)。
// AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 的 Q16 · Q17):
//   · 不再只认航段、港口、执照 —— 任何登记过的主语都可以合进一块(1c-3 的年结、预测、转账、缴纳……都住在清单页上)。
//   · 【一次操作只说一次】一次操作碰到几条记录(一次批量录汇率 = N 条汇率;一次冻结预测 = 新一张 + 旧一张)时,
//     以前每条记录各出一条;现在按 record_trail 的 op_key 并:几条记录读回来的行合在一起、同一行只留一份,
//     再交给同一个造句器造成【一条】,Record 一栏列出它碰到的那几条记录。航段与港口那种"同一件事在三条记录里"
//     从此不靠"整句逐字相同"去重,而是结构上就是一条(同一行只有一份)。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { Refusal } from '@/app/components/ui/refusal'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { trailDict, TRAIL_LOG_BEGAN_AT } from '@/lib/trail/dict'
import { fill, fromRecordTrail, mergeByOperation, mergeKey, type TrailRow } from '@/lib/trail/render'
import { formatTrailStamp } from '@/lib/dates'
import AuditTrailList, { OlderEntriesLink, type ViewEntry } from './AuditTrailList'
import { PAGE, type TrailSubject } from './AuditTrail'

// AUDIT-TRAIL-1c-3:一条记录有自己的页时(重估分录、汇率、删掉的对账单……)交一个 href,Record 一栏就是一个链接 ——
//   撤回了的汇率、删掉的对账单从这里打得开(1c-2 留下的"没有入口")。一次操作碰到几条记录时 Record 一栏只说名字。
//   anchor:一页上不止一段时各用各的(/finance/close 的锁期与年结)。
export type ListTrailRecord = { subject: TrailSubject; id: string; label: string; href?: string | null }
/** 每一个用 ListTrail 的清单页一句开场白 —— 字面量写全(check-trail-wording 按字面认"这个键有人用") */
type IntroKey = 'listTrail.intro.lanes' | 'listTrail.intro.licences'
    | 'listTrail.intro.yearCloses' | 'listTrail.intro.revaluations' | 'listTrail.intro.depreciation' | 'listTrail.intro.fxRates'
    | 'listTrail.intro.forecasts' | 'listTrail.intro.payroll' | 'listTrail.intro.costSettlement' | 'listTrail.intro.wht'
    | 'listTrail.intro.transfers' | 'listTrail.intro.importMappings' | 'listTrail.intro.deletedStatements'

// refused:调用方在【找记录】那一步就已经被挡(/finance/processing-costs:成本条目的读规则是加工的码)—— 画成一句具名的
//   拒绝,不画成"这里什么都没记过"(一个 0 行的读数要先问是谁读的)。
export default async function ListTrail({ records, intro, show, anchor = 'audit-trail', refused = false }: {
    records: ListTrailRecord[]
    intro: IntroKey
    show: number
    anchor?: string
    refused?: boolean
}) {
    const supabase = await createClient()
    const dict = trailDict(await getBaseCurrency())
    const heading = (
        <>
            <h2 className="mb-1">{TRAIL_TEXT['section.title']}</h2>
            <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">{TRAIL_TEXT[intro]}</p>
        </>
    )
    if (refused) {
        return (
            <section id={anchor} data-audit-trail="refused" className="mt-8 border-t pt-6">
                {heading}
                <p className="text-sm"><Refusal>{TRAIL_TEXT.restricted}</Refusal>{' '}{TRAIL_TEXT['refusal.notPermitted']}</p>
            </section>
        )
    }
    const results = await Promise.all(records.map(async (r) => ({
        r, res: await supabase.rpc('record_trail', { p_subject: r.subject, p_id: r.id, p_entries: show }) })))
    // 每一行记下它从哪一条记录读回来(同一行被两条记录读到,只留第一条的那一份)
    const merged: { row: TrailRow; rec: ListTrailRecord }[] = []
    const seenRow = new Set<string>()
    let more = false
    for (const { r, res } of results) {
        if (res.error) {
            const code = res.error.message.split('|')[0]
            // 页面的门已经放行,这里被拒 = 登记表与页面对不上 —— 说出来,不画成"什么都没发生"
            if (code === 'TRAIL_NOT_PERMITTED' || code === 'TRAIL_SUBJECT_UNKNOWN') {
                return (
                    <section id={anchor} data-audit-trail="refused" className="mt-8 border-t pt-6">
                        {heading}
                        <p className="text-sm"><Refusal>{TRAIL_TEXT.restricted}</Refusal>{' '}
                            {TRAIL_TEXT[code === 'TRAIL_NOT_PERMITTED' ? 'refusal.notPermitted' : 'refusal.unknown']}</p>
                    </section>
                )
            }
            throw new Error(`record_trail(${r.subject} ${r.label}) failed: ${res.error.message}`)
        }
        const rows = mustRows(res, `record_trail(${r.subject} ${r.label})`)
        if (rows.some((x) => x.more)) more = true
        for (const x of rows) {
            const row = fromRecordTrail(x as Parameters<typeof fromRecordTrail>[0])
            const k = mergeKey(row, x.seq)
            if (k && seenRow.has(k)) continue
            if (k) seenRow.add(k)
            merged.push({ row, rec: r })
        }
    }
    const unique: ViewEntry[] = mergeByOperation(dict, merged)
    unique.sort((a, b) => (a.at < b.at ? 1 : a.at > b.at ? -1 : 0))
    const shown = unique.slice(0, show)
    if (unique.length > show) more = true
    return (
        <section id={anchor} data-audit-trail={shown.length ? 'entries' : 'empty'} className="mt-8 border-t pt-6">
            {heading}
            {shown.length === 0
                ? <p className="text-sm text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['listTrail.empty']}</p>
                : <AuditTrailList entries={shown} withRecord divider={fill(TRAIL_TEXT.divider, { date: formatTrailStamp(TRAIL_LOG_BEGAN_AT) })} />}
            {more && <OlderEntriesLink href={`?trail=${show + PAGE}#${anchor}`} />}
        </section>
    )
}
