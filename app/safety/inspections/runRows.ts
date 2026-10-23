import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):巡检记录清单的【一份】读取 —— /safety/inspections 与导出路由共用。
// 页面只画最近 RUNS_SHOWN 次(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 次,共 M 次」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在巡检时刻之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatAuditStamp } from '@/lib/dates'
import { getTranslations } from '@/lib/i18n/server'
import type { RunRow } from './InspectionTables'

type Client = SupabaseClient<Database>

/** 页面画多少次 —— 与转换之前同一个数。 */
export const RUNS_SHOWN = 200

export type RunDbRow = {
    id: string; code: string; template_code: string; template_name: string; inspected_at: string; inspector_label: string
    pass_count: number; fail_count: number; na_count: number; finding_count: number; open_finding_count: number; corrected_by_run_code: string | null
}

export function runsCount(supabase: Client) {
    return supabase.from('inspection_run_rows').select('id', { count: 'exact', head: true })
}

export function runsPage(supabase: Client, from: number, to: number) {
    return supabase
        .from('inspection_run_rows')
        .select('id, code, template_code, template_name, inspected_at, inspector_label, pass_count, fail_count, na_count, finding_count, open_finding_count, corrected_by_run_code')
        .order('inspected_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as RunDbRow[] | null }))
}

export async function shapeRunRows(rows: RunDbRow[]): Promise<RunRow[]> {
    const t = await getTranslations()
    return rows.map((r) => ({
        id: r.id, code: r.code, checklist: `${r.template_code} · ${r.template_name}`, inspected: formatAuditStamp(r.inspected_at), inspectedAt: r.inspected_at,
        inspector: r.inspector_label,
        counts: t('safety.inspections.counts', { pass: String(r.pass_count), fail: String(r.fail_count), na: String(r.na_count) }),
        findings: r.finding_count === 0 ? '—' : t('safety.inspections.findingsCount', { n: String(r.finding_count), open: String(r.open_finding_count) }),
        openFindings: r.open_finding_count > 0,
        corrected: r.corrected_by_run_code ? t('safety.inspections.correctedBy', { code: r.corrected_by_run_code }) : null,
    }))
}
