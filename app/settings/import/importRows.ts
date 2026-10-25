import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-23 TABLE-EXPORT-2b Q1):导入历史的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 IMPORTS_SHOWN 次(从前是一句不说的 .limit(20)),表上方 RowCapNotice 说出「前 N 次,共 M 次」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在导入时刻之后补 id —— 翻页要一个【唯一】的次序。
// 「谁」走与别的页面同一个取名器(loadActorNames),而且是【数据】(名字 / 受限 / 没记人),不是一段 JSX —— 它要穿过 JSON 路由。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatAuditStamp } from '@/lib/dates'
import { getTranslations } from '@/lib/i18n/server'
import { loadActorNames } from '@/app/components/ActorName'
import type { ImportBatchRow } from './ImportHistoryTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/** 页面画多少次 —— 与转换之前同一个数。 */
export const IMPORTS_SHOWN = 20

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):只画最近 IMPORTS_SHOWN 次 → 在数据库里排(排在截取之前)。
 *   列键 → `import_batches` 上的列;「哪张表」按库里的表名排。「谁」是另查出来的名字、编号区间是拼出来的一句:不可排(规矩 ③)。
 *   默认 = 今天的 ORDER BY:imported_at DESC,平局按 id —— 它是一份日志,默认仍是导入序。
 */
export const IMPORT_SORT = { when: 'imported_at', table: 'target_table', file: 'file_name', rows: 'row_count' } as const
export type ImportSortKey = keyof typeof IMPORT_SORT
const IMPORT_SORT_DEFAULT: ListSort<ImportSortKey> = { key: 'when', dir: 'desc' }

export function parseImportSort(sp: Record<string, string | string[] | undefined>): ListSort<ImportSortKey> {
    return parseListSort(sp, Object.keys(IMPORT_SORT) as ImportSortKey[], IMPORT_SORT_DEFAULT)
}

/** 导出路由的地址:带上当前排序(TABLE-EXPORT-1 Q2:导出按当前的排序取全体)。 */
export function importsExportHref(sort: ListSort<ImportSortKey>): string {
    return `/settings/import/history/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}

export type ImportDbRow = {
    id: string; target_table: string; file_name: string; row_count: number; code_first: string; code_last: string
    imported_at: string; imported_by: string | null
}

export function importsCount(supabase: Client) {
    return supabase.from('import_batches').select('id', { count: 'exact', head: true })
}

export function importsPage(supabase: Client, from: number, to: number, sort: ListSort<ImportSortKey> = IMPORT_SORT_DEFAULT) {
    return applyListSort(
        supabase
            .from('import_batches')
            .select('id, target_table, file_name, row_count, code_first, code_last, imported_at, imported_by'),
        sort, IMPORT_SORT, [['imported_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as ImportDbRow[] | null }))
}

export async function shapeImportRows(supabase: Client, rows: ImportDbRow[]): Promise<ImportBatchRow[]> {
    const t = await getTranslations()
    // AUDIT-TRAIL-1d-1(Tim 的 Q24):不持 hr.view 的读者只认得出自己 —— 认不出的那一格是「受限」,没记人的是「—」
    const names = await loadActorNames(supabase, rows.map((b) => b.imported_by))
    return rows.map((b) => {
        const name = b.imported_by ? names.names.get(b.imported_by) ?? null : null
        return {
            id: b.id,
            whenLabel: formatAuditStamp(b.imported_at),
            tableLabel: t(`import.table.${b.target_table}`),
            fileName: b.file_name,
            rowCount: b.row_count,
            codeRange: `${b.code_first} … ${b.code_last}`,
            whoName: name,
            whoRestricted: name === null && !!b.imported_by && names.restricted,
            importedAt: b.imported_at,
        }
    })
}
