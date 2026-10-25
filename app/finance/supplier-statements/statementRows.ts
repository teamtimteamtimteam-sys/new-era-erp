import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):签发过的供应商对账单清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 STATEMENTS_SHOWN 份(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 份,共 M 份」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在 issued_at 之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import type { StatementRow } from './StatementsTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/** 页面画多少份 —— 与转换之前同一个数。 */
export const STATEMENTS_SHOWN = 300

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `supplier_statement_rows` 上的列(lib/listSort.ts 的规矩)。
 *   只画前 STATEMENTS_SHOWN 份,所以在数据库里排:那 300 份是【按选中的次序】取的前 300 份。
 *   供应商那一格以供应商编号打头 —— 按编号排;期间按期末日排;期末余额本来就是本位币那一列;PDF 按最新版本号排。
 *   「被取代」那一格是拼出来的一句话(带取代它的单号),不可排。
 * ★ 默认不变(Q7):签发时刻新的在前,平局按 id。
 */
export const SUPPLIER_STATEMENT_SORT = {
    code: 'code', supplier: 'supplier_code', period: 'period_end', closing: 'closing_base', issued: 'issued_at', pdf: 'latest_version',
} as const
export type SupplierStatementSortKey = keyof typeof SUPPLIER_STATEMENT_SORT
const SUPPLIER_STATEMENT_SORT_DEFAULT: ListSort<SupplierStatementSortKey> = { key: 'issued', dir: 'desc' }

export type SupplierStatementListParams = { sort: ListSort<SupplierStatementSortKey> }

export function parseSupplierStatementListParams(sp: { sort?: string; dir?: string }): SupplierStatementListParams {
    return { sort: parseListSort(sp, Object.keys(SUPPLIER_STATEMENT_SORT) as SupplierStatementSortKey[], SUPPLIER_STATEMENT_SORT_DEFAULT) }
}

/** 导出路由的地址:这一页没有筛选,只带排序。 */
export function supplierStatementExportHref(p: SupplierStatementListParams): string {
    return `/finance/supplier-statements/export?${setSortParams(new URLSearchParams(), p.sort).toString()}`
}

export type StatementDbRow = {
    id: string; code: string; supplier_code: string; supplier_name: string; period_start: string; period_end: string; base_currency: string
    closing_base: number; issued_at: string; superseded_at: string | null; superseded_by_code: string | null; latest_version: number | null
}

export function statementCount(supabase: Client) {
    return supabase.from('supplier_statement_rows').select('id', { count: 'exact', head: true })
}

export function statementPage(supabase: Client, p: SupplierStatementListParams, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:ORDER BY 在 .range 之前 —— 上限按选中的次序取
    return applyListSort(
        supabase.from('supplier_statement_rows')
            .select('id, code, supplier_code, supplier_name, period_start, period_end, base_currency, closing_base, issued_at, superseded_at, superseded_by_code, latest_version'),
        p.sort, SUPPLIER_STATEMENT_SORT, [['issued_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as StatementDbRow[] | null }))
}

export async function shapeStatementRows(list: StatementDbRow[]): Promise<StatementRow[]> {
    const [locale, t] = await Promise.all([getLocale(), getTranslations()])
    return list.map((r) => ({
        id: r.id, code: r.code, supplier: `${r.supplier_code} · ${r.supplier_name}`,
        period: `${formatDate(r.period_start, locale)} – ${formatDate(r.period_end, locale)}`,
        closing: formatAmount(Number(r.closing_base), r.base_currency),
        issued: formatAuditStamp(r.issued_at),
        superseded: r.superseded_at ? t('supplierStatements.supersededBy', { code: r.superseded_by_code ?? '' }) : null,
        latestVersion: r.latest_version ? `v${r.latest_version}` : t('supplierStatements.noPdfYet'),
        periodRaw: `${r.period_start} – ${r.period_end}`,
        closingAmt: Number(r.closing_base),
        baseCurrency: r.base_currency,
        issuedRaw: r.issued_at,
    }))
}
