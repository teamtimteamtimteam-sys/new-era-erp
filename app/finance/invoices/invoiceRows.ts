import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):发票列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者同一套筛选、同一个 select、同一个映射。
// 排序 issue_date DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
//
// ★ 两条路(与页面原样):在册的读 invoice_status(带已收 / 未收 / 逾期);【作废的不在那张视图里】,
//   另查 invoices_masked 并标注为已作废(其结算数字无意义,留空)。筛「全部」时作废的接在后面。
// ★ 本模块交出去的日期是【原始的 YYYY-MM-DD】—— 从前作废那一支在这里先 formatDate 一次、页面再 formatDate 一次
//   (lib/dates.ts「显示用的日期被当成数据」);格式化只在 shape 里做一次。
// ★ 三条读取从前都只解构 data、不看 error:一次失败会画成一张空表。现在它们走调用方的 mustRows / fetchAllPages。
// ★ TABLE-EXPORT-2 Q8(Tim 2026-10-22):合计在 invoices_masked 里按 data.view_prices 遮,未收是从合计算出来的,于是一起是 NULL。
//   从前屏幕把这个 NULL 画成「—」—— 与「作废的单没有结算数」一模一样;现在带上 canViewPrices,屏幕与导出同说「受限」。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { parseDateRange } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { canViewPrices } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import type { InvoiceRow } from './InvoicesTable'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'
import { readAll } from '@/lib/readAll'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `invoice_status` 上的列(lib/listSort.ts 的规矩)。
 *   合计 / 未收按视图上那一列排:invoice_status 读的是 invoices_masked,看不见价格的人那里是 NULL(规矩 ②),排在最后。
 *   客户【不可排】:作废那一支读 invoices_masked,客户名是嵌出来的,那张关系上没有这一列 ——
 *   只看作废时它会悄悄退回默认次序,表头却画着箭头。
 * ★ 默认不变(Q7):开票日新的在前,平局按 id。
 */
export const INVOICE_SORT = {
    code: 'code', issueDate: 'issue_date', dueDate: 'due_date', total: 'total_base',
    settled: 'settled_base', open: 'open_base', state: 'payment_state',
} as const
export type InvoiceSortKey = keyof typeof INVOICE_SORT
const INVOICE_SORT_DEFAULT: ListSort<InvoiceSortKey> = { key: 'issueDate', dir: 'desc' }
/**
 * 作废那一支(invoices_masked)上的同名列。已收 / 未收 / 状态在作废的单上一律是空 / 「作废」——
 * 全体相等,按哪一列排都是对的;那几个键在这一支上走默认次序。
 */
const VOID_SORT = { code: 'code', issueDate: 'issue_date', dueDate: 'due_date', total: 'total_base' } as const

export type InvoiceListParams = { dateFrom: string; dateTo: string; state: string; status: 'issued' | 'void' | 'all'; sort: ListSort<InvoiceSortKey> }

export function parseInvoiceListParams(sp: { date_from?: string; date_to?: string; state?: string; status?: string; sort?: string; dir?: string }): InvoiceListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    return {
        dateFrom, dateTo,
        state: ['unpaid', 'partial', 'paid', 'overdue'].includes(sp.state ?? '') ? sp.state! : '',
        status: sp.status === 'void' || sp.status === 'all' ? sp.status : 'issued',
        sort: parseListSort(sp, Object.keys(INVOICE_SORT) as InvoiceSortKey[], INVOICE_SORT_DEFAULT),
    }
}

/** 两条路都映射成这个形状。日期是原始的 YYYY-MM-DD。 */
export type InvoiceDbRow = {
    invoice_id: string; code: string; kind: string | null; customer_name: string | null
    issue_date: string; due_date: string; total_base: number | null
    settled_base: number | null; open_base: number | null; payment_state: string | null
    days_overdue: number | null; overdue: boolean; is_void: boolean
}

interface Chain {
    gte(c: string, v: string): Chain
    lte(c: string, v: string): Chain
    eq(c: string, v: string | boolean): Chain
}
function applyDates<T>(query: T, p: InvoiceListParams): T {
    let chain = query as unknown as Chain
    if (p.dateFrom) chain = chain.gte('issue_date', p.dateFrom)
    if (p.dateTo) chain = chain.lte('issue_date', p.dateTo)
    return chain as unknown as T
}
function applyState<T>(query: T, p: InvoiceListParams): T {
    let chain = applyDates(query, p) as unknown as Chain
    if (p.state === 'overdue') chain = chain.eq('overdue', true)
    else if (p.state) chain = chain.eq('payment_state', p.state)
    return chain as unknown as T
}

/**
 * TABLE-FEATURES-2(Tim 2026-10-25 Q1 · 2026-10-26 Q2):表尾合计 —— 所有符合筛选的发票,库算(db/functions/list_totals_invoices.sql)。
 * 作废的被冲销抵掉、加 0:status='void' 时库返回零行(表尾不画),'all' 与 'issued' 同一个合计。
 * 合计 / 未收按 data.view_prices 整个读者地遮 → 「受限」;已收不遮。
 */
export async function invoiceTotals(supabase: Client, p: InvoiceListParams): Promise<ListTotal[]> {
    const res = await readAll(() => supabase.rpc('list_totals_invoices', {
        p_date_from: p.dateFrom || undefined, p_date_to: p.dateTo || undefined,
        p_state: p.state || undefined, p_status: p.status,
    }), { label: 'list_totals_invoices', key: ['grp', 'currency', 'measure', 'total', 'restricted'] })
    return shapeListTotals(mustRows(res, 'invoices totals'))
}

// ── 在册(invoice_status)──
export function issuedCount(supabase: Client, p: InvoiceListParams) {
    return applyState(supabase.from('invoice_status').select('invoice_id', { count: 'exact', head: true }), p)
}
export function issuedPage(supabase: Client, p: InvoiceListParams, from: number, to: number) {
    return applyListSort(
        applyState(supabase.from('invoice_status').select('*'), p),
        p.sort, INVOICE_SORT, [['issue_date', 'desc'], ['invoice_id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({
            error,
            data: data === null ? null : (data as unknown as Omit<InvoiceDbRow, 'is_void'>[]).map((r) => ({ ...r, is_void: false })),
        }))
}

// ── 作废(invoices_masked)──
type VoidDbRow = { id: string; code: string; kind: string | null; issue_date: string; due_date: string; total_base: number | null; customers: { legal_name: string } | null }
export function voidCount(supabase: Client, p: InvoiceListParams) {
    // 数与取读同一张遮蔽视图(从前数的是 invoices 基表、取的是 invoices_masked —— 两边各一个口径)
    return applyDates(supabase.from('invoices_masked').select('id', { count: 'exact', head: true }).eq('status', 'void'), p)
}
export function voidPage(supabase: Client, p: InvoiceListParams, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:这一支上没有的键(全体相等的那几列)走默认次序 —— 见 VOID_SORT
    const vsort: ListSort<keyof typeof VOID_SORT> = p.sort.key in VOID_SORT
        ? { key: p.sort.key as keyof typeof VOID_SORT, dir: p.sort.dir }
        : { key: 'issueDate', dir: 'desc' }
    return applyListSort(
        applyDates(
            supabase.from('invoices_masked')
                .select('id, code, kind, issue_date, due_date, total_base, customers(legal_name)')
                .eq('status', 'void'),
            p,
        ),
        vsort, VOID_SORT, [['issue_date', 'desc'], ['id', 'asc']],
    )
        .range(from, to)
        .then(({ data, error }) => ({
            error,
            data: data === null ? null : (data as unknown as VoidDbRow[]).map((i): InvoiceDbRow => ({
                invoice_id: i.id,
                code: i.code,
                kind: i.kind,
                customer_name: i.customers?.legal_name ?? null,
                issue_date: i.issue_date,
                due_date: i.due_date,
                total_base: i.total_base,
                settled_base: null,
                open_base: null,
                payment_state: null,
                days_overdue: null,
                overdue: false,
                is_void: true,
            })),
        }))
}

/** 导出路由的地址:同一套筛选,不带 page。 */
export function invoiceExportHref(p: InvoiceListParams): string {
    const params = new URLSearchParams()
    if (p.dateFrom) params.set('date_from', p.dateFrom)
    if (p.dateTo) params.set('date_to', p.dateTo)
    if (p.state) params.set('state', p.state)
    if (p.status !== 'issued') params.set('status', p.status)
    setSortParams(params, p.sort)
    const qs = params.toString()
    return qs ? `/finance/invoices/export?${qs}` : '/finance/invoices/export'
}

export async function shapeInvoiceRows(rows: InvoiceDbRow[]): Promise<InvoiceRow[]> {
    // 合计 / 已收 / 未收三列的列头都不写币种 —— 数字自己带(CCY-1)
    const [locale, baseCurrency, canPrices] = await Promise.all([getLocale(), getBaseCurrency(), canViewPrices()])
    return rows.map((r) => ({
        invoiceId: r.invoice_id,
        code: r.code,
        kind: r.kind,
        customerName: r.customer_name,
        issueDate: formatDate(r.issue_date, locale),
        issueDateRaw: r.issue_date,
        dueDate: formatDate(r.due_date, locale),
        dueDateRaw: r.due_date,
        daysOverdue: r.days_overdue,
        overdue: r.overdue,
        totalBase: r.total_base,
        settledBase: r.settled_base,
        openBase: r.open_base,
        paymentState: r.payment_state,
        isVoid: r.is_void,
        baseCurrency,
        canViewPrices: canPrices,
    }))
}
