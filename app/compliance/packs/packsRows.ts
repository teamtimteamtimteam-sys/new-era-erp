import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):冻下来的合规包清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 PACKS_SHOWN 份(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 份,共 M 份」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在月份与冻结时刻之后补 id —— 翻页要一个【唯一】的次序。
// 「被谁取代」与「最新 PDF 版本」按 id 反查(分批,inChunks)—— 取代它的那一份可能不在这一批里。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatAuditStamp } from '@/lib/dates'
import { getTranslations } from '@/lib/i18n/server'
import { inChunks } from '@/lib/export/serverRows'
import type { PackRow } from './PacksTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { readAllIn } from '@/lib/readAll'

type Client = SupabaseClient<Database>

/** 页面画多少份 —— 与转换之前同一个数。 */
export const PACKS_SHOWN = 300

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):只画前 PACKS_SHOWN 份 → 在数据库里排(排在截取之前)。
 *   列键 → `compliance_packs` 上的列。「最新 PDF」是另查出来的、「被谁取代」是拼出来的一句话:不可排(规矩 ③)。
 *   默认 = 今天的 ORDER BY:period_month DESC,平局 frozen_at DESC、id。
 */
export const PACK_SORT = { code: 'code', month: 'period_month', frozen: 'frozen_at' } as const
export type PackSortKey = keyof typeof PACK_SORT
const PACK_SORT_DEFAULT: ListSort<PackSortKey> = { key: 'month', dir: 'desc' }

export function parsePackSort(sp: Record<string, string | string[] | undefined>): ListSort<PackSortKey> {
    return parseListSort(sp, Object.keys(PACK_SORT) as PackSortKey[], PACK_SORT_DEFAULT)
}

/** 导出路由的地址:带上当前排序(TABLE-EXPORT-1 Q2:导出按当前的排序取全体)。 */
export function packsExportHref(sort: ListSort<PackSortKey>): string {
    return `/compliance/packs/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}

export type PackDbRow = {
    id: string; code: string; period_month: string; frozen_at: string
    superseded_at: string | null; superseded_by: string | null; superseded_reason: string | null
}

export function packsCount(supabase: Client) {
    return supabase.from('compliance_packs').select('id', { count: 'exact', head: true })
}

export function packsPage(supabase: Client, from: number, to: number, sort: ListSort<PackSortKey> = PACK_SORT_DEFAULT) {
    return applyListSort(
        supabase
            .from('compliance_packs')
            .select('id, code, period_month, frozen_at, superseded_at, superseded_by, superseded_reason'),
        sort, PACK_SORT, [['period_month', 'desc'], ['frozen_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as PackDbRow[] | null }))
}

export async function shapePackRows(supabase: Client, rows: PackDbRow[]): Promise<PackRow[]> {
    const t = await getTranslations()
    const ids = rows.map((r) => r.id)
    const byIds = rows.map((r) => r.superseded_by).filter((x): x is string => !!x)
    const [issues, coders] = await Promise.all([
        inChunks(ids, (c) => readAllIn(c, (__ids) => supabase.from('compliance_pack_issues').select('pack_id, version').in('pack_id', __ids), { label: 'compliance_pack_issues' })
            .then(({ data, error }) => ({ error, data: data as { pack_id: string; version: number }[] | null })), 'compliance_pack_issues'),
        inChunks(byIds, (c) => readAllIn(c, (__ids) => supabase.from('compliance_packs').select('id, code').in('id', __ids), { label: 'compliance_packs' })
            .then(({ data, error }) => ({ error, data: data as { id: string; code: string }[] | null })), 'compliance_packs superseded_by'),
    ])
    const codeById = new Map(coders.map((r) => [r.id, r.code]))
    const latest = new Map<string, number>()
    for (const i of issues) latest.set(i.pack_id, Math.max(latest.get(i.pack_id) ?? 0, i.version))
    return rows.map((r) => ({
        id: r.id, code: r.code, month: r.period_month.slice(0, 7), frozen: formatAuditStamp(r.frozen_at), frozenAt: r.frozen_at,
        superseded: r.superseded_at ? t('compliancePacks.supersededBy', { code: codeById.get(r.superseded_by ?? '') ?? '', reason: r.superseded_reason ?? '' }) : null,
        latestVersion: latest.has(r.id) ? `v${latest.get(r.id)}` : t('compliancePacks.noPdfYet'),
    }))
}
