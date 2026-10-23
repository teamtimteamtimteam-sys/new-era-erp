import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):销售订单清单的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 ORDERS_SHOWN 张(从前是一句不说的 .limit(200)),表上方 RowCapNotice 说出「前 N 张,共 M 张」;
// 导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。排序在订单日之后补 id —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import { soStatusKey } from './salesOrderTypes'
import type { SalesOrderRow } from './SalesOrdersTable'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const ORDERS_SHOWN = 200

export type OrderDbRow = {
    id: string; code: string; order_date: string; status: string
    currency: string; customers: { code: string; legal_name: string } | null
}

export function ordersCount(supabase: Client) {
    return supabase.from('sales_orders').select('id', { count: 'exact', head: true }).is('deleted_at', null)
}

export function ordersPage(supabase: Client, from: number, to: number) {
    return supabase
        .from('sales_orders')
        .select('id, code, order_date, status, currency, customers ( code, legal_name )')
        .is('deleted_at', null)
        .order('order_date', { ascending: false })
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as OrderDbRow[] | null }))
}

export async function shapeOrderRows(rows: OrderDbRow[]): Promise<SalesOrderRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    return rows.map((r) => ({
        id: r.id,
        code: r.code,
        customerLabel: r.customers ? `${r.customers.code} — ${r.customers.legal_name}` : '—',
        // 日期按 locale 格式化在服务端做完 —— locale 不过 RSC 边界
        orderDateLabel: formatDate(r.order_date, locale),
        orderDate: r.order_date,
        statusLabel: t(soStatusKey(r.status)),
        currency: r.currency,
    }))
}
