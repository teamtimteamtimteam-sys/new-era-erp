// app/settings/change-history/export/route.ts
// GOLIVE-2 第 13 行 · 变更记录的导出(Tim 2026-10-23 TABLE-EXPORT-3 Q7 · 2026-10-30 Q3)。Q7 原文:
//   "Change-history export: both dates required; longest range 366 days; the 50,000-row cap still refuses anything larger and states the count;
//    every filter on the page applies, including "key events only"; one row per field changed (When, Who, Record, What happened, Field,
//    Old value, New value), hidden values written as "Restricted"."
//   Q3(2026-10-30):50,000 的上限数的是【库这一侧筛选】(日期 · 区域 / 记录类型 · 记录 · 人)下的已记录变更(change_log_count);
//   「只看关键事件」在写文件时由同一个造句器判(lib/trail/render.ts —— 库里判不了);拒绝说出那个数,并请人收窄日期区间。
// 门与页面同一个判据(FN.changeHistory = data.view_change_log);读法与页面同一支(change_log_page,一块 500 次操作,一笔事务不被切开),
//   筛选与页面同一份(lib/trail/changeLogFilters.ts)。只回 JSON;文件由浏览器那一半写(ChangeHistoryExport.tsx,与表格导出同一套 xlsx / csv)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustOne } from '@/lib/db-helpers'
import { getBaseCurrency } from '@/lib/currency'
import { isYmd } from '@/lib/dateFilter'
import { EXPORT_CAP, exportDenied } from '@/lib/export/serverRows'
import { TRAIL_TABLES } from '@/lib/trail/catalogue.generated'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { trailDict } from '@/lib/trail/dict'
import { buildEntries, fill, fromChangeLog, type Entry, type RecordRef } from '@/lib/trail/render'
import { changeLogFilterArgs, readChangeLog, CHANGE_LOG_WHO_UUID } from '@/lib/trail/changeLogFilters'

export const maxDuration = 300

const MAX_DAYS = 366

type LogRow = Parameters<typeof fromChangeLog>[0] & { seq: number; txid: number }
export type ChangeHistoryExportRow = {
    when: string; who: string; record: string; what: string; field: string
    old: string | null; oldRestricted: boolean; new: string | null; newRestricted: boolean
}

function recordText(r: RecordRef | null): string {
    if (!r) return ''
    const thing = TRAIL_TABLES[r.table]?.[0] ?? 'record'
    if (r.label) return r.gone ? fill(TRAIL_TEXT['value.sinceDeleted'], { label: r.label }) : r.label
    return fill(r.gone ? TRAIL_TEXT['value.goneGeneric'] : TRAIL_TEXT['value.unnamed'], { thing })
}

/** 一次操作 → 一个字段一行(没有字段的那一次操作:一行,字段空着) */
function rowsOf(e: Entry): ChangeHistoryExportRow[] {
    const base = { when: e.at, who: e.who.restricted ? TRAIL_TEXT.restricted : e.who.text, record: recordText(e.record),
                   what: e.titleRestricted ? TRAIL_TEXT.restricted : (e.titlePart ? `${e.title} ${e.titlePart.text}` : e.title) }
    const out: ChangeHistoryExportRow[] = []
    for (const l of e.lines) {
        if (l.t === 'change') out.push({ ...base, field: l.label, old: l.old.restricted ? null : l.old.text, oldRestricted: !!l.old.restricted,
                                         new: l.new.restricted ? null : l.new.text, newRestricted: !!l.new.restricted })
        else if (l.t === 'value') out.push({ ...base, field: l.label, old: null, oldRestricted: false,
                                             new: l.value.restricted ? null : l.value.text, newRestricted: !!l.value.restricted })
    }
    return out.length ? out : [{ ...base, field: '', old: null, oldRestricted: false, new: null, newRestricted: false }]
}

export async function GET(request: NextRequest) {
    if (!(await canEnter(FN.changeHistory.permission))) return exportDenied()
    const sp = request.nextUrl.searchParams
    const from = isYmd(sp.get('from') ?? '') ? (sp.get('from') as string) : ''
    const to = isYmd(sp.get('to') ?? '') ? (sp.get('to') as string) : ''
    if (!from || !to) return Response.json({ code: 'EXPORT_DATES_REQUIRED' }, { status: 400 })
    const days = Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000) + 1
    if (days < 1 || days > MAX_DAYS) return Response.json({ code: 'EXPORT_RANGE_TOO_LONG', days, max: MAX_DAYS }, { status: 400 })

    const supabase = await createClient()
    // 区域与记录类型:与页面同一个白名单(只认真的挂着记录的表)
    const filters = mustOne(await supabase.rpc('change_log_filters'), 'change_log_filters') as unknown as { tables: string[] }
    const logged = new Set(filters.tables)
    const types = Object.entries(TRAIL_TABLES).filter(([tbl]) => logged.has(tbl)).map(([tbl, [, a]]) => ({ tbl, area: a }))
    const areaParam = sp.get('area') ?? ''
    const area = types.some((x) => x.area === areaParam) ? areaParam : ''
    const typeParam = sp.get('type') ?? ''
    const type = types.some((x) => x.tbl === typeParam && (!area || x.area === area)) ? typeParam : ''
    const whoParam = sp.get('who') ?? ''
    const who = whoParam === 'system' || whoParam === 'removed' ? whoParam : CHANGE_LOG_WHO_UUID.test(whoParam) ? whoParam : ''
    const record = (sp.get('record') ?? '').trim().slice(0, 200)
    const keyOnly = sp.get('key') === '1'
    let recordIds: string[] | undefined
    if (record) {
        recordIds = (mustOne(await supabase.rpc('change_log_find_records', { p_text: record }), 'change_log_find_records') ?? []) as string[]
        if (recordIds.length === 0) return Response.json({ rows: [] })
    }
    const f = { from, to, type, tables: !type && area ? types.filter((x) => x.area === area).map((x) => x.tbl) : undefined, recordIds, who }

    // Q3:先数(库这一侧的筛选);超过上限就不读,说出那个数
    const n = Number(mustOne(await supabase.rpc('change_log_count', changeLogFilterArgs(f)), 'change_log_count') ?? 0)
    if (n > EXPORT_CAP) return Response.json({ code: 'EXPORT_TOO_MANY_ROWS', count: n, cap: EXPORT_CAP }, { status: 413 })

    // 一块一块往前读到底(lib/trail/changeLogFilters.ts 的 readChangeLog:一块 20 次操作,撞上 8 秒的语句上限就减半;一笔事务不会被切成两块)
    //   cast 的理由与页面那一处相同:共用的读法只认 { data, error },两支函数的参数由 changeLogFilterArgs 一处给出
    const { rows } = await readChangeLog<LogRow>(
            // unpaged-ok: change_log_page returns ONE jsonb (the row cap cannot cut it); change_log_rows is only called with p_row_limit 100
            (fn, args) => supabase.rpc(fn as never, args as never), f, Number.POSITIVE_INFINITY)
    // 与页面同一个排法:一次操作 = 一笔事务,按它里面最大的 seq(新的在前)
    const maxSeq = new Map<number, number>()
    for (const r of rows) maxSeq.set(r.txid, Math.max(maxSeq.get(r.txid) ?? 0, r.seq))
    const rank = new Map([...maxSeq.entries()].sort((a, b) => b[1] - a[1]).map(([tx], i) => [tx, i]))
    const entries = buildEntries(trailDict(await getBaseCurrency()), rows.map((r) => fromChangeLog(r, rank.get(r.txid) ?? 0)))
    return Response.json({ rows: entries.filter((e) => !keyOnly || e.keyEvent).flatMap(rowsOf), changes: n })
}
