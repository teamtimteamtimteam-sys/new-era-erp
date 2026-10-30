import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):运费单据登记簿的【一份】读取 —— 页面与导出路由共用。
// 页面只画最近 FREIGHT_SHOWN 张(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在 doc_date 之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getBaseCurrency } from '@/lib/currency'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import type { FreightRow } from './FreightTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'
import { readAll } from '@/lib/readAll'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const FREIGHT_SHOWN = 200

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `freight_documents` 上的列(lib/listSort.ts 的规矩)。
 *   只画前 FREIGHT_SHOWN 张,所以在数据库里排:那 200 张是【按选中的次序】取的前 200 张。货代名是嵌出来的,不可排。
 * ★ 默认不变(Q7):单据日新的在前,平局按 id。
 */
export const FREIGHT_SORT = { code: 'code', date: 'doc_date', amount: 'amount_base', basis: 'allocation_basis', payment: 'payment_status' } as const
export type FreightSortKey = keyof typeof FREIGHT_SORT
const FREIGHT_SORT_DEFAULT: ListSort<FreightSortKey> = { key: 'date', dir: 'desc' }

export type FreightListParams = { sort: ListSort<FreightSortKey> }

export function parseFreightListParams(sp: { sort?: string; dir?: string }): FreightListParams {
    return { sort: parseListSort(sp, Object.keys(FREIGHT_SORT) as FreightSortKey[], FREIGHT_SORT_DEFAULT) }
}

/** 导出路由的地址:这一页没有筛选,只带排序。 */
export function freightExportHref(p: FreightListParams): string {
    return `/finance/freight/export?${setSortParams(new URLSearchParams(), p.sort).toString()}`
}

export type FreightDbRow = {
    id: string
    code: string
    doc_date: string
    amount_base: number
    allocation_basis: string
    payment_status: string
    status: string
    suppliers: { legal_name: string } | null
}

/**
 * TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):表尾合计 —— 所有在册(deleted_at IS NULL)运费单的本位币金额,库算
 * (db/functions/list_totals_freight.sql);冲销的只是被标记,加 0。是全体,不是画出来的前 FREIGHT_SHOWN 张。
 */
export async function freightTotals(supabase: Client): Promise<ListTotal[]> {
    const res = await readAll(() => supabase.rpc('list_totals_freight'), { label: 'list_totals_freight', key: ['grp', 'currency', 'measure', 'total', 'restricted'] })
    return shapeListTotals(mustRows(res, 'freight totals'))
}

export function freightCount(supabase: Client) {
    return supabase.from('freight_documents').select('id', { count: 'exact', head: true }).is('deleted_at', null)
}

export function freightPage(supabase: Client, p: FreightListParams, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:ORDER BY 在 .range 之前 —— 上限按选中的次序取
    return applyListSort(
        supabase
            .from('freight_documents')
            .select('id, code, doc_date, amount_base, allocation_basis, payment_status, status, suppliers ( legal_name )')
            .is('deleted_at', null),
        p.sort, FREIGHT_SORT, [['doc_date', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as FreightDbRow[] | null }))
}

export async function shapeFreightRows(rows: FreightDbRow[]): Promise<FreightRow[]> {
    const [locale, baseCurrency] = await Promise.all([getLocale(), getBaseCurrency()])
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        docDate: formatDate(r.doc_date, locale),
        docDateRaw: r.doc_date,
        forwarder: r.suppliers?.legal_name ?? '—',
        amountBase: r.amount_base,
        baseCurrency,
        allocationBasis: r.allocation_basis,
        paymentStatus: r.payment_status,
        reversed: r.status === 'reversed',
    }))
}
