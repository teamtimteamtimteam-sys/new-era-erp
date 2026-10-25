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
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'

type Client = SupabaseClient<Database>

/** 页面画多少张 —— 与转换之前同一个数。 */
export const ORDERS_SHOWN = 200

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):只画前 ORDERS_SHOWN 张 → 在数据库里排(排在截取之前)。
 *   列键 → `sales_orders` 上的列;状态按库里的状态码排。客户是嵌入查出来的名字:不可排(规矩 ③)。
 *   默认 = 今天的 ORDER BY:order_date DESC,平局按 id。
 */
export const ORDER_SORT = { code: 'code', date: 'order_date', status: 'status', currency: 'currency' } as const
export type OrderSortKey = keyof typeof ORDER_SORT
const ORDER_SORT_DEFAULT: ListSort<OrderSortKey> = { key: 'date', dir: 'desc' }

export function parseOrderSort(sp: Record<string, string | string[] | undefined>): ListSort<OrderSortKey> {
    return parseListSort(sp, Object.keys(ORDER_SORT) as OrderSortKey[], ORDER_SORT_DEFAULT)
}

/** 导出路由的地址:带上当前排序(TABLE-EXPORT-1 Q2:导出按当前的排序取全体)。 */
export function ordersExportHref(sort: ListSort<OrderSortKey>): string {
    return `/sales/orders/export?${setSortParams(new URLSearchParams(), sort).toString()}`
}

export type OrderDbRow = {
    id: string; code: string; order_date: string; status: string
    currency: string; customers: { code: string; legal_name: string } | null
}

export function ordersCount(supabase: Client) {
    return supabase.from('sales_orders').select('id', { count: 'exact', head: true }).is('deleted_at', null)
}

export function ordersPage(supabase: Client, from: number, to: number, sort: ListSort<OrderSortKey> = ORDER_SORT_DEFAULT) {
    return applyListSort(
        supabase
            .from('sales_orders')
            .select('id, code, order_date, status, currency, customers ( code, legal_name )')
            .is('deleted_at', null),
        sort, ORDER_SORT, [['order_date', 'desc'], ['id', 'asc']],
    )
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
