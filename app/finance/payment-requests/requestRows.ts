import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):付款申请列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者走同一套筛选(状态合集)、
// 同一个 select、同一个映射。排序在 created_at DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
// 收款人名按 id 反查(供应商 / 员工 / 客户三张查名视图),分批问。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatDate } from '@/lib/dates'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { inChunks } from '@/lib/export/serverRows'
import { requestSubjectLabel } from './requestSubject'
import type { PaymentRequestRow } from './PaymentRequestsTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'
import { readAll, readAllIn } from '@/lib/readAll'

type Client = SupabaseClient<Database>

// 与 db/tables/payment_requests.sql 的 status CHECK 同一组取值;'all' 是本页唯一的合集。
// ★ SYSTEM-MAP-2(Tim 2026-10-27 Q5,PAYMENT-REQUESTS-FILTER-MIXES-QUEUES):默认是「等审批」(submitted)——
//   从前的默认「未了结」把等 CFO 批的与已批准、等财务付的混在一张清单里:两种动作、两类人。那个合集撤掉了;
//   「已批准 · 等付款」(approved)是紧挨着的第二个筛选。旧地址 ?status=open 落回默认。
export const REQUEST_STATUSES = ['submitted', 'approved', 'paid', 'rejected', 'withdrawn'] as const
export const REQUEST_FILTER_DEFAULT = 'submitted'

/** 'submitted'(默认)· 'all' · 一个具体状态 */
export function parseRequestFilter(status: string | undefined): string {
    return status === 'all' || (REQUEST_STATUSES as readonly string[]).includes(status ?? '') ? (status as string) : REQUEST_FILTER_DEFAULT
}
function statusSet(filter: string): string[] | null {
    return filter === 'all' ? null : [filter]
}

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `payment_requests` 上的列(lib/listSort.ts 的规矩)。
 *   金额按【本位币】那一列排:各行币种不同,原币金额放在一起比没有意义。收款人是查出来的,不可排。
 * ★ 默认不变(Q7):提出时刻新的在前,平局按 id。
 */
export const REQUEST_SORT = { code: 'code', kind: 'kind', amount: 'amount_base', status: 'status', created: 'created_at' } as const
export type RequestSortKey = keyof typeof REQUEST_SORT
const REQUEST_SORT_DEFAULT: ListSort<RequestSortKey> = { key: 'created', dir: 'desc' }

export function parseRequestSort(sp: { sort?: string; dir?: string }): ListSort<RequestSortKey> {
    return parseListSort(sp, Object.keys(REQUEST_SORT) as RequestSortKey[], REQUEST_SORT_DEFAULT)
}

interface Chain { in(c: string, v: string[]): Chain }
function applyFilters<T>(query: T, filter: string): T {
    let chain = query as unknown as Chain
    const set = statusSet(filter)
    if (set) chain = chain.in('status', set)
    return chain as unknown as T
}

export type RequestDbRow = {
    id: string; code: string; kind: string; status: string; counterparty_type: string | null
    supplier_id: string | null; employee_id: string | null; customer_id: string | null
    amount_ccy: number; currency: string; created_at: string
    bank_account_code: string | null; to_account_code: string | null; period_month: string | null
}

export function requestCount(supabase: Client, filter: string) {
    return applyFilters(supabase.from('payment_requests').select('id', { count: 'exact', head: true }), filter)
}

/**
 * TABLE-FEATURES-2(Tim Q1):表尾合计 —— db/functions/list_totals_payment_requests.sql。
 *   传同一个解析过的筛选(parseRequestFilter 的结果);库里按 statusSet 同一条规矩展开('all' → 不限;其余 → 那一个状态)。
 */
export async function requestTotals(supabase: Client, filter: string): Promise<ListTotal[]> {
    return shapeListTotals(mustRows(await readAll(() => supabase.rpc('list_totals_payment_requests', { p_status: filter }), { label: 'list_totals_payment_requests', key: ['grp', 'currency', 'measure', 'total', 'restricted'] }), 'payment requests totals'))
}

export function requestPage(supabase: Client, filter: string, sort: ListSort<RequestSortKey>, from: number, to: number) {
    return applyListSort(
        applyFilters(
            supabase
                .from('payment_requests')
                .select('id, code, kind, status, counterparty_type, supplier_id, employee_id, customer_id, amount_ccy, currency, created_at, bank_account_code, to_account_code, period_month'),
            filter,
        ),
        sort, REQUEST_SORT, [['created_at', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as RequestDbRow[] | null }))
}

/** 导出路由的地址:同一个筛选,不带 page。TABLE-FEATURES-1 Q9:带上同一份排序。 */
export function requestExportHref(filter: string, sort: ListSort<RequestSortKey>): string {
    const params = new URLSearchParams()
    if (filter !== REQUEST_FILTER_DEFAULT) params.set('status', filter)
    setSortParams(params, sort)
    return `/finance/payment-requests/export?${params.toString()}`
}

export async function shapeRequestRows(supabase: Client, rows: RequestDbRow[]): Promise<PaymentRequestRow[]> {
    const [locale, t] = await Promise.all([getLocale(), getTranslations()])
    const ids = (k: 'supplier_id' | 'employee_id' | 'customer_id') => rows.map((r) => r[k]).filter((x): x is string => !!x)
    type NameRow = { id: string; legal_name: string }
    // 查名视图:这一页的门是 finance.view,基表挂的是各自模块(FIX-2a 那一课)。
    const names = (view: 'supplier_lookup' | 'employee_lookup' | 'customer_lookup', list: string[]) =>
        inChunks(list, (chunk) => readAllIn(chunk, (__ids) => supabase.from(view).select('id, legal_name').in('id', __ids), { label: 'view' })
            .then(({ data, error }) => ({ error, data: data as unknown as NameRow[] | null })), view)
    const lists = await Promise.all([
        names('supplier_lookup', ids('supplier_id')),
        names('employee_lookup', ids('employee_id')),
        names('customer_lookup', ids('customer_id')),
    ])
    const nameById = new Map<string, string>()
    for (const list of lists) for (const n of list) nameById.set(n.id, n.legal_name)
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        kind: r.kind,
        // Batch B:转账与代扣税没有收款人 —— 印它挪的是什么(requestSubject.ts)
        payee: requestSubjectLabel(t, locale, r) ?? nameById.get(r.supplier_id ?? r.employee_id ?? r.customer_id ?? '') ?? '—',
        amountCcy: r.amount_ccy,
        currency: r.currency,
        status: r.status,
        createdDate: formatDate(r.created_at, locale),
        createdAtRaw: r.created_at,
    }))
}
