import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):采购单列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一套筛选、同一个 select、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在 order_date DESC 之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一天开的两张单不再随机互换)。
//
// ★ 两条路(与页面原样):已取消的不在 purchase_order_status 里,筛 cancelled 时另查 purchase_orders_masked
//   (其预付 / 收货进度无意义,置 null)。
// ★ 本模块交出去的日期是【原始的 YYYY-MM-DD】—— 从前已取消那一支在这里先 formatDate 一次、
//   页面再 formatDate 一次(lib/dates.ts:210-216「显示用的日期被当成数据」);格式化只在 shape 里做一次。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { parseDateRange } from '@/lib/dateFilter'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { can, canViewPurchasePrices } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import type { PurchaseOrderRow } from './OrdersTable'

type Client = SupabaseClient<Database>

export const PO_STATUSES = ['draft', 'confirmed', 'receiving', 'closed', 'cancelled']

export type PoListParams = { dateFrom: string; dateTo: string; supplier: string; status: string }

export function parsePoListParams(sp: { date_from?: string; date_to?: string; supplier?: string; status?: string }): PoListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    return {
        dateFrom,
        dateTo,
        supplier: (sp.supplier ?? '').trim(),
        status: PO_STATUSES.includes(sp.status ?? '') ? sp.status! : '',
    }
}

/** 库里的一行(两条路都映射成这个形状)。日期是原始的 YYYY-MM-DD。 */
export type PoDbRow = {
    po_id: string
    code: string
    supplier_name: string | null
    order_date: string
    expected_delivery_date: string | null
    currency: string
    estimated_total_ccy: number | null
    // PO-GST-1:清单也说得出税。carries_tax 为 false = 这张单开在采购单携带税
    // 之前(或 GST 未注册时)—— **不是零税**,所以 GST 那一格印「—」不印 0.00。
    tax_total_ccy: number | null
    gross_total_ccy: number | null
    carries_tax: boolean
    prepaid_base: number | null
    prepaid_remaining_base: number | null
    receipt_pct: number | null
    status: string
}

interface Chain {
    gte(c: string, v: string): Chain
    lte(c: string, v: string): Chain
    eq(c: string, v: string): Chain
}
function applyFilters<T>(query: T, p: PoListParams): T {
    let chain = query as unknown as Chain
    if (p.dateFrom) chain = chain.gte('order_date', p.dateFrom)
    if (p.dateTo) chain = chain.lte('order_date', p.dateTo)
    if (p.supplier) chain = chain.eq('supplier_id', p.supplier)
    return chain as unknown as T
}
function applyStatus<T>(query: T, p: PoListParams): T {
    let chain = applyFilters(query, p) as unknown as Chain
    if (p.status) chain = chain.eq('status', p.status)
    return chain as unknown as T
}

export function poCount(supabase: Client, p: PoListParams) {
    if (p.status === 'cancelled') {
        // 只看已取消:视图里没有它们,直接查本表
        return applyFilters(
            supabase.from('purchase_orders').select('id', { count: 'exact', head: true }).eq('status', 'cancelled').is('deleted_at', null),
            p,
        )
    }
    return applyStatus(supabase.from('purchase_order_status').select('po_id', { count: 'exact', head: true }), p)
}

type CancelledDbRow = {
    id: string; code: string; order_date: string; expected_delivery_date: string | null; currency: string
    estimated_total_ccy: number | null; tax_total_ccy: number | null; gross_total_ccy: number | null
    carries_tax: boolean; status: string; suppliers: { legal_name: string } | null
}

export function poPage(
    supabase: Client, p: PoListParams, from: number, to: number,
): PromiseLike<{ data: PoDbRow[] | null; error: { message: string } | null }> {
    if (p.status === 'cancelled') {
        return applyFilters(
            supabase
                .from('purchase_orders_masked')
                .select('id, code, order_date, expected_delivery_date, currency, estimated_total_ccy, tax_total_ccy, gross_total_ccy, carries_tax, status, suppliers(legal_name)')
                .eq('status', 'cancelled')
                .is('deleted_at', null),
            p,
        )
            .order('order_date', { ascending: false })
            .order('id', { ascending: true })
            .range(from, to)
            .then(({ data, error }) => ({
                error,
                data: data === null ? null : (data as unknown as CancelledDbRow[]).map((r) => ({
                    po_id: r.id,
                    code: r.code,
                    supplier_name: r.suppliers?.legal_name ?? null,
                    order_date: r.order_date,
                    expected_delivery_date: r.expected_delivery_date,
                    currency: r.currency,
                    estimated_total_ccy: r.estimated_total_ccy,
                    tax_total_ccy: r.tax_total_ccy,
                    gross_total_ccy: r.gross_total_ccy,
                    carries_tax: r.carries_tax,
                    prepaid_base: null,
                    prepaid_remaining_base: null,
                    receipt_pct: null,
                    status: r.status,
                })),
            }))
    }
    return applyStatus(
        supabase
            .from('purchase_order_status')
            .select('po_id, code, supplier_name, order_date, expected_delivery_date, currency, estimated_total_ccy, tax_total_ccy, gross_total_ccy, carries_tax, prepaid_base, prepaid_remaining_base, receipt_pct, status'),
        p,
    )
        .order('order_date', { ascending: false })
        .order('po_id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as PoDbRow[] | null }))
}

/** 导出路由的地址:同一套筛选,不带 page(Q2:导出取全部匹配行)。 */
export function poExportHref(p: PoListParams): string {
    const params = new URLSearchParams()
    if (p.dateFrom) params.set('date_from', p.dateFrom)
    if (p.dateTo) params.set('date_to', p.dateTo)
    if (p.supplier) params.set('supplier', p.supplier)
    if (p.status) params.set('status', p.status)
    const qs = params.toString()
    return qs ? `/purchasing/orders/export?${qs}` : '/purchasing/orders/export'
}

// 金额在服务端按各自的币种格式化好 —— formatAmount 与 baseCurrency 不过边界。
export async function shapePoRows(rows: PoDbRow[]): Promise<PurchaseOrderRow[]> {
    const locale = await getLocale()
    const [canFinance, canPurchasePrices, baseCurrency] = await Promise.all([
        can('module.finance.view'),
        // TABLE-EXPORT-1:三个金额列在 purchase_orders_masked 里按 data.view_purchase_prices 遮
        //   (估算总额 · 税额 · 应付总额)。从前屏幕把这个 null 画成「—」—— 与「没有算过税」的「—」一模一样;
        //   现在它们走 <MaskedValue>,屏幕与导出同说「受限」。
        canViewPurchasePrices(),
        // 预付列是本位币 —— 从 currencies.is_base 取,不写死
        getBaseCurrency(),
    ])
    return rows.map((r) => {
        const gross = r.carries_tax ? r.gross_total_ccy : r.estimated_total_ccy
        // 【没有算过税】给 null,由表印「—」;绝不折成 0.00
        const tax = r.carries_tax ? (r.tax_total_ccy ?? 0) : null
        return {
            poId: r.po_id,
            code: r.code,
            status: r.status,
            supplierName: r.supplier_name ?? '—',
            orderDate: formatDate(r.order_date, locale),
            orderDateRaw: r.order_date,
            expectedDelivery: formatDate(r.expected_delivery_date, locale) ?? '—',
            expectedDeliveryRaw: r.expected_delivery_date,
            currency: r.currency,
            netTotal: r.estimated_total_ccy === null ? null : formatAmount(r.estimated_total_ccy, r.currency),
            netTotalAmt: r.estimated_total_ccy,
            taxTotal: tax === null ? null : formatAmount(tax, r.currency),
            taxTotalAmt: tax,
            grossTotal: gross === null ? null : formatAmount(gross, r.currency),
            grossTotalAmt: gross,
            prepaid: r.prepaid_base === null ? null : formatAmount(r.prepaid_base, baseCurrency),
            baseCurrency,
            prepaidAmt: r.prepaid_base,
            prepaidRemaining:
                (r.prepaid_remaining_base ?? 0) > 0 ? formatAmount(r.prepaid_remaining_base ?? 0, baseCurrency) : null,
            canFinance,
            canPurchasePrices,
            receiptPct: r.receipt_pct,
        }
    })
}
