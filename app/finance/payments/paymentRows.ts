import 'server-only'

// TABLE-EXPORT-2a(Tim 2026-10-22 Q2):收付款列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts,上限 50,000);两者走同一套筛选、同一个 select、
// 同一个「库里的行 → 表的行」映射。排序在 created_at DESC 之后补 id —— 翻页取全要一个【唯一】的次序。
// 往来单位名按 id 反查(客户 / 供应商两张名视图),分批问(导出一次可以有几万个 id)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { parseDateRange } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { formatDate } from '@/lib/dates'
import { getLocale } from '@/lib/i18n/server'
import { inChunks } from '@/lib/export/serverRows'
import type { PaymentRow } from './PaymentsTable'

type Client = SupabaseClient<Database>

export type PaymentListParams = { dateFrom: string; dateTo: string; direction: '' | 'in' | 'out' }

export function parsePaymentListParams(sp: { date_from?: string; date_to?: string; direction?: string }): PaymentListParams {
    const { dateFrom, dateTo } = parseDateRange(sp)
    return { dateFrom, dateTo, direction: sp.direction === 'in' || sp.direction === 'out' ? sp.direction : '' }
}

export type PaymentDbRow = {
    id: string; code: string; direction: string; customer_id: string | null; supplier_id: string | null
    amount_ccy: number; currency: string; amount_base: number; bank_account_code: string; payment_date: string; status: string
}

// 过滤链(payments 不可变表,无软删)。最小链式子集,避免 supabase 深泛型。
interface Chain {
    gte(c: string, v: string): Chain
    lte(c: string, v: string): Chain
    eq(c: string, v: string): Chain
}
function applyFilters<T>(query: T, p: PaymentListParams): T {
    let chain = query as unknown as Chain
    if (p.dateFrom) chain = chain.gte('payment_date', p.dateFrom)
    if (p.dateTo) chain = chain.lte('payment_date', p.dateTo)
    if (p.direction) chain = chain.eq('direction', p.direction)
    return chain as unknown as T
}

export function paymentCount(supabase: Client, p: PaymentListParams) {
    return applyFilters(supabase.from('payments').select('id', { count: 'exact', head: true }), p)
}

export function paymentPage(supabase: Client, p: PaymentListParams, from: number, to: number) {
    return applyFilters(
        supabase
            .from('payments')
            .select('id, code, direction, customer_id, supplier_id, amount_ccy, currency, amount_base, bank_account_code, payment_date, status'),
        p,
    )
        .order('created_at', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as PaymentDbRow[] | null }))
}

/** 导出路由的地址:同一套筛选,不带 page(Q2:导出取全部匹配行)。 */
export function paymentExportHref(p: PaymentListParams): string {
    const params = new URLSearchParams()
    if (p.dateFrom) params.set('date_from', p.dateFrom)
    if (p.dateTo) params.set('date_to', p.dateTo)
    if (p.direction) params.set('direction', p.direction)
    const qs = params.toString()
    return qs ? `/finance/payments/export?${qs}` : '/finance/payments/export'
}

export async function shapePaymentRows(supabase: Client, rows: PaymentDbRow[]): Promise<PaymentRow[]> {
    const [locale, baseCurrency] = await Promise.all([getLocale(), getBaseCurrency()])
    const customerIds = rows.map((r) => r.customer_id).filter((x): x is string => !!x)
    const supplierIds = rows.map((r) => r.supplier_id).filter((x): x is string => !!x)
    type NameRow = { id: string; legal_name: string }
    const [customers, suppliers] = await Promise.all([
        inChunks(customerIds, (ids) => supabase.from('customer_lookup').select('id, legal_name').in('id', ids)
            .then(({ data, error }) => ({ error, data: data as unknown as NameRow[] | null })), 'customer_lookup'),
        // LOG-1b:【这一处绝不过滤 counterparty_type】—— 它把 id 换成名字,不是选择器。
        //         过滤它会让【货代那几笔运费付款】的收款方名字变成空白,而那正是本模块存在的理由。
        inChunks(supplierIds, (ids) => supabase.from('supplier_lookup').select('id, legal_name').in('id', ids)
            .then(({ data, error }) => ({ error, data: data as unknown as NameRow[] | null })), 'supplier_lookup'),
    ])
    const nameById = new Map<string, string>()
    for (const c of customers) nameById.set(c.id, c.legal_name)
    for (const s of suppliers) nameById.set(s.id, s.legal_name)
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        paymentDate: formatDate(r.payment_date, locale),
        paymentDateRaw: r.payment_date,
        direction: r.direction,
        counterparty: nameById.get(r.customer_id ?? r.supplier_id ?? '') ?? '—',
        amountCcy: r.amount_ccy,
        currency: r.currency,
        amountBase: r.amount_base,
        baseCurrency,
        bankAccountCode: r.bank_account_code,
        status: r.status,
    }))
}
