// app/settings/change-history/page.tsx
// HISTORY-1(Tim 的 Q26 · Q13 · Q14,2026-09-28):变更记录 —— 一张【读得到】的通用记录。
// AUDIT-TRAIL-1a(Tim 的 Q14 · Q15 · Q28 · Q30 · Q31,2026-09-29):改写成与每一页底部的审计记录【同一种话】。
//
// 【门】data.view_change_log(只授 admin 与 cfo)。一条注册表条目、两个属主(设置 + 财务的报表组)—— 没有变。
// 【读法只有一支】change_log_rows()(SECURITY DEFINER,自己查码、自己遮蔽 —— 遮蔽与审计记录是同一步,Q5)。
//   它按【事务】分页(p_by_entry):一次操作一条(Q2),每一行带回人名、所属单据与引用值的名字(Q40)。
//   造句走 lib/trail/render.ts 的 buildEntries —— 与页底的审计记录是同一个造句器,所以两处说同样的话(Q30)。
// 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一条不少。"Key events only"只是筛,不是删。
// 【机器字一个都不上屏】(Q30 点名的那一串):表名、row_key、列名、原始 JSON、ISO 时刻、"No session · service_role"
//   全部换掉 —— Record type 与 Area 取 lib/trail/catalogue.generated.ts 的英文名;时刻是 DD/MM/YYYY HH:MM(Q15)。
// 【页面外框随界面语言,记录内容只说英文】(Q7):标题、筛选的标签走 t();每一条记录的句子来自英文目录。
// 【筛选】日期(from / to,含当天)· 区域 · 记录类型 · 记录(按单据号或名字,change_log_find_records)·
//   谁(人 / System (automatic) / Removed account)· 只看关键事件。GET 表单,链接可以抄给别人。
// 【分页】最新的在前,每页 25 次操作;键集分页(?before=<一次操作里最大的 seq>)。只看关键事件时往前多读
//   (最多 100 次操作)凑满一页,并说出这一页藏了几条日常编辑。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { isYmd } from '@/lib/dateFilter'
import { ListPage } from '@/app/components/ui/list-page'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { DateFilterInput } from '@/app/components/ui/date-filter-input'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { documentHref } from '@/lib/search/documentHref'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { TRAIL_TABLES } from '@/lib/trail/catalogue.generated'
import { trailDict } from '@/lib/trail/dict'
import { buildEntries, fill, fromChangeLog, type RecordRef } from '@/lib/trail/render'
import AuditTrailList, { type ViewEntry } from '@/app/components/trail/AuditTrailList'

const PAGE_SIZE = 25
const KEY_SCAN = 100
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type LogRow = Parameters<typeof fromChangeLog>[0] & { seq: number }
type Filters = {
    tables: string[]
    people: { employee: string; actor: { state: string; name?: string | null } }[]
    has_system: boolean
    has_removed: boolean
}
type SP = { from?: string; to?: string; area?: string; type?: string; record?: string; who?: string; key?: string; before?: string }

/** 一张单据的落点;角色不是单据,走它自己的页 */
function recordHref(r: RecordRef): string | null {
    if (!r.id || r.gone) return null
    if (r.table === 'roles') return `/settings/roles/${r.id}`
    if (!r.route || !r.link_mode || !r.doc_key) return null
    return documentHref({ key: r.doc_key, route: r.route, linkMode: r.link_mode, id: r.id, code: r.label ?? '' })
}
function recordText(r: RecordRef | null): string | null {
    if (!r) return null
    const thing = TRAIL_TABLES[r.table]?.[0] ?? 'record'
    if (r.label) return r.gone ? fill(TRAIL_TEXT['value.sinceDeleted'], { label: r.label }) : r.label
    return fill(r.gone ? TRAIL_TEXT['value.goneGeneric'] : TRAIL_TEXT['value.unnamed'], { thing })
}

export default async function ChangeHistoryPage({ searchParams }: { searchParams: Promise<SP> }) {
    const denied = await requireFunction(FN.changeHistory)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // 【失败必须失败】RPC 一律 mustOne / mustRows —— 读不出来不许画成"没有改动"。
    const filters = mustOne(await supabase.rpc('change_log_filters'), 'change_log_filters') as unknown as Filters
    const logged = new Set(filters.tables)
    // 记录类型与区域:只列【真的挂着记录】的那些,名字取英文目录
    const types = Object.entries(TRAIL_TABLES)
        .filter(([tbl]) => logged.has(tbl))
        .map(([tbl, [name, area]]) => ({ tbl, name: name[0].toUpperCase() + name.slice(1), area }))
        .sort((a, b) => a.name.localeCompare(b.name))
    const areas = [...new Set(types.map((x) => x.area))].sort()

    const from = isYmd(sp.from ?? '') ? (sp.from as string) : ''
    const to = isYmd(sp.to ?? '') ? (sp.to as string) : ''
    const area = areas.includes(sp.area ?? '') ? (sp.area as string) : ''
    const type = types.some((x) => x.tbl === sp.type && (!area || x.area === area)) ? (sp.type as string) : ''
    const record = (sp.record ?? '').trim().slice(0, 200)
    const who = sp.who === 'system' || sp.who === 'removed' ? sp.who : UUID.test(sp.who ?? '') ? (sp.who as string) : ''
    const keyOnly = sp.key === '1'
    const before = /^\d{1,18}$/.test(sp.before ?? '') ? (sp.before as string) : ''

    // 按单据号或名字找 → 一组 id;找不到就直说,不去读(一个空的 id 组不是"不筛")
    let recordIds: string[] | undefined
    if (record) {
        recordIds = (mustOne(await supabase.rpc('change_log_find_records', { p_text: record }), 'change_log_find_records') ?? []) as string[]
    }
    const noMatch = !!record && (!recordIds || recordIds.length === 0)

    let rows: LogRow[] = []
    if (!noMatch) {
        const res = await supabase.rpc('change_log_rows', {
            p_from: from || undefined,
            p_to: to || undefined,
            p_table: type || undefined,
            p_tables: !type && area ? types.filter((x) => x.area === area).map((x) => x.tbl) : undefined,
            p_record_ids: recordIds,
            p_actor: UUID.test(who) ? who : undefined,
            p_no_session: who === 'system',
            p_removed_account: who === 'removed',
            p_by_entry: true,
            p_before: before ? Number(before) : undefined,
            p_limit: keyOnly ? KEY_SCAN : PAGE_SIZE + 1,
        })
        rows = mustRows(res, 'change_log_rows') as unknown as LogRow[]
    }

    // 一次操作 = 一笔事务;按它里面最大的 seq 排(新的在前),也拿它当下一页的键
    const maxSeq = new Map<number, number>()
    for (const r of rows) maxSeq.set(r.txid, Math.max(maxSeq.get(r.txid) ?? 0, r.seq))
    const order = [...maxSeq.entries()].sort((a, b) => b[1] - a[1])
    const rank = new Map(order.map(([tx], i) => [tx, i]))
    const dict = trailDict(await getBaseCurrency())
    const built = buildEntries(dict, rows.map((r) => fromChangeLog(r, rank.get(r.txid) ?? 0)))
    // built 与 order 同序(buildEntries 按 order 排)
    const shown: ViewEntry[] = []
    let consumed = 0
    let hiddenRoutine = 0
    for (const e of built) {
        if (shown.length === PAGE_SIZE) break
        consumed++
        if (keyOnly && !e.keyEvent) { hiddenRoutine++; continue }
        shown.push({ ...e, recordText: recordText(e.record), recordHref: e.record ? recordHref(e.record) : null })
    }
    const hasOlder = keyOnly ? consumed < built.length || order.length === KEY_SCAN : order.length > PAGE_SIZE
    const cursor = consumed > 0 ? order[consumed - 1][1] : null

    function href(next: Partial<Record<keyof SP, string>>) {
        const p = new URLSearchParams()
        const v: Record<string, string> = { from, to, area, type, record, who, key: keyOnly ? '1' : '', before: '', ...next }
        for (const [k, val] of Object.entries(v)) if (val) p.set(k, val)
        const s = p.toString()
        return s ? `/settings/change-history?${s}` : '/settings/change-history'
    }

    return (
        <ListPage
            title={t('changeHistory.title')}
            intro={t('changeHistory.intro')}
            notices={
                <p className="text-sm text-[color:var(--brand-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4 max-w-3xl">
                    {t('changeHistory.maskNote')}
                </p>
            }
            state={{ kind: 'ok' }}
        >
            {/* ── 筛选:日期 · 区域 · 记录类型 · 记录 · 谁 · 只看关键事件 ─────────────── */}
            <form className="flex flex-wrap items-end gap-2 mb-4 text-sm" action="/settings/change-history">
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterFrom')}
                    <DateFilterInput name="from" defaultValue={from} />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterTo')}
                    <DateFilterInput name="to" defaultValue={to} />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterArea')}
                    <select name="area" defaultValue={area} className={CONTROL_SELECT}>
                        <option value="">{t('changeHistory.allAreas')}</option>
                        {areas.map((a) => <option key={a} value={a}>{a}</option>)}
                    </select>
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterType')}
                    <select name="type" defaultValue={type} className={CONTROL_SELECT}>
                        <option value="">{t('changeHistory.allTypes')}</option>
                        {areas.filter((a) => !area || a === area).map((a) => (
                            <optgroup key={a} label={a}>
                                {types.filter((x) => x.area === a).map((x) => <option key={x.tbl} value={x.tbl}>{x.name}</option>)}
                            </optgroup>
                        ))}
                    </select>
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterRecord')}
                    <input type="text" name="record" defaultValue={record} placeholder={t('changeHistory.recordPlaceholder')}
                           className={CONTROL_INPUT} />
                </label>
                <label className="flex flex-col gap-1">
                    {t('changeHistory.filterActor')}
                    <select name="who" defaultValue={who} className={CONTROL_SELECT}>
                        <option value="">{t('changeHistory.allActors')}</option>
                        {filters.people.filter((p) => p.actor.state === 'person' && p.actor.name).map((p) => (
                            <option key={p.employee} value={p.employee}>{p.actor.name}</option>
                        ))}
                        {filters.has_system && <option value="system">{TRAIL_TEXT['who.system']}</option>}
                        {filters.has_removed && <option value="removed">{TRAIL_TEXT['who.removed']}</option>}
                    </select>
                </label>
                <label className="flex items-center gap-1.5 pb-1.5">
                    <input type="checkbox" name="key" value="1" defaultChecked={keyOnly} />
                    {t('changeHistory.keyOnly')}
                </label>
                <Button variant="secondary" type="submit">
                    {t('common.filter')}
                </Button>
                <Link href="/settings/change-history" className="px-2 py-1 hover:underline app-link">
                    {t('changeHistory.clear')}
                </Link>
            </form>

            <section data-change-history={noMatch ? 'no-match' : shown.length ? 'entries' : 'empty'}>
                {noMatch ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('changeHistory.noRecordMatch', { q: record })}</p>
                ) : shown.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('changeHistory.empty')}</p>
                ) : (
                    <AuditTrailList entries={shown} withRecord />
                )}
                {keyOnly && hiddenRoutine > 0 && (
                    <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                        {fill(TRAIL_TEXT[hiddenRoutine === 1 ? 'summary.keyHidden.one' : 'summary.keyHidden.many'], { n: hiddenRoutine })}
                    </p>
                )}
            </section>

            {/* ── 分页:最新 / 较早(键集,按一次操作里最大的 seq 倒序)─────────────────── */}
            <div className="flex flex-wrap items-center gap-3 mt-4 text-sm">
                <span className="text-[color:var(--brand-muted-text)]">{t('changeHistory.pageNote', { n: PAGE_SIZE })}</span>
                {before && (
                    <Link href={href({ before: '' })} className="hover:underline app-link">
                        {t('changeHistory.newest')}
                    </Link>
                )}
                {hasOlder && cursor !== null && (
                    <Link href={href({ before: String(cursor) })} className="hover:underline app-link">
                        {t('changeHistory.older')}
                    </Link>
                )}
            </div>
        </ListPage>
    )
}
