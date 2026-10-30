// app/settings/change-history/page.tsx
// HISTORY-1(Tim 的 Q26 · Q13 · Q14,2026-09-28):变更记录 —— 一张【读得到】的通用记录。
// AUDIT-TRAIL-1a(Tim 的 Q14 · Q15 · Q28 · Q30 · Q31,2026-09-29):改写成与每一页底部的审计记录【同一种话】。
//
// 【门】data.view_change_log(只授 admin 与 cfo)。一条注册表条目、两个属主(设置 + 财务的报表组)—— 没有变。
// 【读法只有一支】change_log_page()(GOLIVE-2;SECURITY DEFINER,自己查码、自己遮蔽 —— 遮蔽与审计记录是同一步,Q5;与 change_log_rows 逐行相同)。
//   它按【事务】分页(p_by_entry):一次操作一条(Q2),每一行带回人名、所属单据与引用值的名字(Q40)。
//   造句走 lib/trail/render.ts 的 buildEntries —— 与页底的审计记录是同一个造句器,所以两处说同样的话(Q30)。
// 【它仍然列出每一次写入】(Q31):系统的、冒烟的、账号事件的,一条不少。"Key events only"只是筛,不是删。
// 【机器字一个都不上屏】(Q30 点名的那一串):表名、row_key、列名、原始 JSON、ISO 时刻、"No session · service_role"
//   全部换掉 —— Record type 与 Area 取 lib/trail/catalogue.generated.ts 的英文名;时刻是 DD/MM/YYYY HH:MM(Q15)。
// 【页面外框随界面语言,记录内容只说英文】(Q7):标题、筛选的标签走 t();每一条记录的句子来自英文目录。
// 【筛选】日期(from / to,含当天)· 区域 · 记录类型 · 记录(按单据号或名字,change_log_find_records)·
//   谁(人 / System (automatic) / Removed account)· 只看关键事件。GET 表单,链接可以抄给别人。
// 【分页】AUDIT-TRAIL-1b-1(Tim 的折入 2,推翻 AT-1a 决定 21):与每一页的审计记录同一个样子 —— 先 20 次操作,
//   然后"Show older entries"把列表【接长】20 次(?show=40,上限 500),不再是"最新 / 较早"两个翻页链接。
//   GOLIVE-2 第 13 行起一次调用 change_log_page 读完(此前是一圈 change_log_rows:事务 200 一块、行 100 一页,show=500 线上 107 s)。
//   只看关键事件时往前多读(要显示的数的 5 倍,上限 1,000)凑满,并说出藏了几条日常编辑。
//   【导出】GOLIVE-2(Tim 2026-10-23 Q7 · 2026-10-30 Q3):./export(两个日期必填,最长 366 天,5 万上限数的是库这一侧筛选下的已记录变更)。
// 【折入 3(Q7)】列表那一段里的每一个字都是英文:列头、每一句、空状态、分页说明、"Show older entries"都来自
//   lib/trail/text.ts;标题、说明、筛选随界面语言走(与任何别的页面的外框一样)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustOne } from '@/lib/db-helpers'
import { isYmd } from '@/lib/dateFilter'
import { ListPage } from '@/app/components/ui/list-page'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { documentHref } from '@/lib/search/documentHref'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { TRAIL_TABLES } from '@/lib/trail/catalogue.generated'
import { trailDict } from '@/lib/trail/dict'
import { buildEntries, fill, fromChangeLog, type RecordRef } from '@/lib/trail/render'
import { readChangeLog, CHANGE_LOG_WHO_UUID as UUID } from '@/lib/trail/changeLogFilters'
import AuditTrailList, { OlderEntriesLink, type ViewEntry } from '@/app/components/trail/AuditTrailList'
import ChangeHistoryExport from './ChangeHistoryExport'

const PAGE = 20
const MAX_SHOW = 500

type LogRow = Parameters<typeof fromChangeLog>[0] & { seq: number }
type Filters = {
    tables: string[]
    people: { employee: string; actor: { state: string; name?: string | null } }[]
    has_system: boolean
    has_removed: boolean
}
type SP = { from?: string; to?: string; area?: string; type?: string; record?: string; who?: string; key?: string; show?: string }

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
    const showN = Number(sp.show)
    const show = Number.isInteger(showN) && showN >= PAGE && showN <= MAX_SHOW ? showN : PAGE

    // 按单据号或名字找 → 一组 id;找不到就直说,不去读(一个空的 id 组不是"不筛")
    let recordIds: string[] | undefined
    if (record) {
        recordIds = (mustOne(await supabase.rpc('change_log_find_records', { p_text: record }), 'change_log_find_records') ?? []) as string[]
    }
    const noMatch = !!record && (!recordIds || recordIds.length === 0)

    const rows: LogRow[] = []
    let exhausted = noMatch
    if (!noMatch) {
        // 要读几次操作:显示 show 条(多读一条用来知道后面还有没有);只看关键事件时多读几倍凑满
        const target = keyOnly ? Math.min(show * 5, 1000) : show + 1
        // GOLIVE-2 第 13 行(Tim 2026-10-30 Q2):一次调用 change_log_page —— 同一道门、同一套筛选、同一段逐行遮蔽,交出的行与原来那一圈
        //   change_log_rows(事务 200 一块、行 100 一页)【逐行相同】(fixture 305,七个角色);库里只把"要哪几次操作"求一次。
        //   年体量种子(顶部按线上的形状)上:show=20 1.40 s → 0.12 s,show=500 30.0 s → 2.65 s(docs/surveys/GOLIVE-2/seed/targets-before-after.txt)。
        //   它回一个 jsonb(不是一组行),所以 PostgREST 的 max_rows 截不到它。线上 authenticated 有 8 秒的语句上限,所以按块读(lib/trail/changeLogFilters.ts)。
        // supabase.rpc 的函数名与参数是按数据库类型逐个定型的;这里交给共用的读法,它只认 { data, error } —— 这一句 cast 关掉的就是那份逐个定型,
        //   而两支函数的参数由 changeLogFilterArgs 一处给出(fixture 305 钉住它们与页面原来那一圈逐行相同)。
        const res = await readChangeLog<LogRow>(
            // unpaged-ok: change_log_page returns ONE jsonb (the row cap cannot cut it); change_log_rows is only called with p_row_limit 100
            (fn, args) => supabase.rpc(fn as never, args as never), {
            from, to, type, tables: !type && area ? types.filter((x) => x.area === area).map((x) => x.tbl) : undefined,
            recordIds, who,
        }, target)
        rows.push(...res.rows)
        exhausted = res.exhausted
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
        if (shown.length === show) break
        consumed++
        if (keyOnly && !e.keyEvent) { hiddenRoutine++; continue }
        shown.push({ ...e, recordText: recordText(e.record), recordHref: e.record ? recordHref(e.record) : null })
    }
    const hasOlder = keyOnly ? consumed < built.length || !exhausted : order.length > show

    const exportDays = from && to ? Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1 : 0
    const exportReady = exportDays >= 1 && exportDays <= 366
    const exportQuery = new URLSearchParams(Object.entries({ from, to, area, type, record, who, key: keyOnly ? '1' : '' }).filter(([, v]) => v)).toString()

    function href(next: Partial<Record<keyof SP, string>>) {
        const p = new URLSearchParams()
        const v: Record<string, string> = { from, to, area, type, record, who, key: keyOnly ? '1' : '', show: '', ...next }
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
            {/* MES-9c:三颗下拉按它最长的那一项撑宽,390 px 上整页溢出 +21 px —— 与 /settings/approvals(MES-9a)同一个修法:max-w-full。 */}
            <form className="flex flex-wrap items-end gap-2 mb-4 text-sm" action="/settings/change-history">
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterFrom')}
                    <DatePicker name="from" defaultValue={from} />
                </label>
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterTo')}
                    <DatePicker name="to" defaultValue={to} />
                </label>
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterArea')}
                    <select name="area" defaultValue={area} className={`${CONTROL_SELECT} max-w-full`}>
                        <option value="">{t('changeHistory.allAreas')}</option>
                        {areas.map((a) => <option key={a} value={a}>{a}</option>)}
                    </select>
                </label>
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterType')}
                    <select name="type" defaultValue={type} className={`${CONTROL_SELECT} max-w-full`}>
                        <option value="">{t('changeHistory.allTypes')}</option>
                        {areas.filter((a) => !area || a === area).map((a) => (
                            <optgroup key={a} label={a}>
                                {types.filter((x) => x.area === a).map((x) => <option key={x.tbl} value={x.tbl}>{x.name}</option>)}
                            </optgroup>
                        ))}
                    </select>
                </label>
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterRecord')}
                    <input type="text" name="record" defaultValue={record} placeholder={t('changeHistory.recordPlaceholder')}
                           className={CONTROL_INPUT} />
                </label>
                <label className="flex flex-col gap-1 min-w-0 max-w-full">
                    {t('changeHistory.filterActor')}
                    <select name="who" defaultValue={who} className={`${CONTROL_SELECT} max-w-full`}>
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

            {/* GOLIVE-2 第 13 行:导出(Q7 · Q3)—— 两个日期都选了、区间不超过 366 天才按得下去;筛选与页面同一份 */}
            <ChangeHistoryExport query={exportQuery} ready={exportReady} />

            <section id="audit-trail" data-change-history={noMatch ? 'no-match' : shown.length ? 'entries' : 'empty'}>
                {noMatch ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{fill(TRAIL_TEXT['summary.noRecordMatch'], { q: record })}</p>
                ) : shown.length === 0 ? (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['summary.empty']}</p>
                ) : (
                    <AuditTrailList entries={shown} withRecord />
                )}
                {keyOnly && hiddenRoutine > 0 && (
                    <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                        {fill(TRAIL_TEXT[hiddenRoutine === 1 ? 'summary.keyHidden.one' : 'summary.keyHidden.many'], { n: hiddenRoutine })}
                    </p>
                )}
                {/* ── 分页:与每一页的审计记录同一个样子 —— 20 条,然后"Show older entries"把列表接长(折入 2)──── */}
                <div className="flex flex-wrap items-center gap-3 mt-4 text-sm">
                    <span className="text-[color:var(--brand-muted-text)]">{fill(TRAIL_TEXT['summary.pageNote'], { n: shown.length })}</span>
                    {hasOlder && show < MAX_SHOW && <OlderEntriesLink href={`${href({ show: String(show + PAGE) })}#audit-trail`} />}
                </div>
                {/* ★ TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q4):「查看更早」到 MAX_SHOW 条就不再出现 —— 从前一句不说,
                    读起来像「没有更早的了」。还有更早的时候说出来,并指出怎么看到它们(收窄筛选)。导出由 GOLIVE-2 加上(上面那一排)。 */}
                {hasOlder && show >= MAX_SHOW && (
                    <p role="status" data-change-history-stop="" className="mt-2 text-sm text-amber-800">
                        {t('changeHistory.stopsAt', { n: String(MAX_SHOW) })}
                    </p>
                )}
            </section>
        </ListPage>
    )
}
