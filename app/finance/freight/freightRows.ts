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

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const FREIGHT_SHOWN = 200

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

export function freightCount(supabase: Client) {
    return supabase.from('freight_documents').select('id', { count: 'exact', head: true }).is('deleted_at', null)
}

export function freightPage(supabase: Client, from: number, to: number) {
    return supabase
        .from('freight_documents')
        .select('id, code, doc_date, amount_base, allocation_basis, payment_status, status, suppliers ( legal_name )')
        .is('deleted_at', null)
        .order('doc_date', { ascending: false })
        .order('id', { ascending: true })
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
