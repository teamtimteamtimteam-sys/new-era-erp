import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):客户名单的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射(含主联系人那一次补查),于是导出不可能比屏幕多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两行不再随机互换)。
//
// ★ Q5 / Q11:旧的 CSV 导出比表多六列(简称 · 税号 · 付款条件 · 贸易术语 · 信用评级 · 地址)。
//   它们作为表【声明】的扩展列留在导出里(CustomersTable 的 exportSpec.extension),
//   所以原始值要在这一份行上 —— select 里多读那几列,页面不画它们。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { formatAuditStamp } from '@/lib/dates'
import { applyCustomerFilters, type CustomerListParams } from './customerQuery'
import type { CustomerTableRow } from './CustomersTable'

type Client = SupabaseClient<Database>

export const CUSTOMER_LIST_SELECT =
    'id, code, legal_name, short_name, country, customer_types, status, tax_id, payment_terms, incoterm, credit_rating, address, created_at'

export function customerCount(supabase: Client, params: CustomerListParams) {
    return applyCustomerFilters(supabase.from('customers').select('id', { count: 'exact', head: true }), params)
}

export function customerPage(supabase: Client, params: CustomerListParams, from: number, to: number) {
    return applyCustomerFilters(supabase.from('customers').select(CUSTOMER_LIST_SELECT), params)
        .order('id', { ascending: true })
        .range(from, to)
}

type CustomerDbRow = NonNullable<Awaited<ReturnType<typeof customerPage>>['data']>[number]
type PrimaryContact = { customer_id: string; name: string; email: string | null; name_inferred: boolean }

export async function shapeCustomerRows(supabase: Client, customers: CustomerDbRow[]): Promise<CustomerTableRow[]> {
    // PARTY-1:联系人搬进了 counterparty_contacts,一个客户可以有好几个 ——
    // 列表这一栏画的是【主联系人】那一行。分开一次查询是因为 PostgREST 的
    // 嵌套过滤在这里要不到"只要 is_primary 的那一行",而在 TS 里再筛一遍
    // 就是把一条筛选写两遍。
    // TABLE-EXPORT-1:按 id 分批 —— 导出一次可能是几万个客户,一个 .in() 塞不下;每批 200 个 id,
    //   结果行同样受 max_rows 管,所以每批再翻页(与 materialRows.ts 同一个写法)。
    const ids = customers.map((c) => c.id)
    const primaryByCustomer = new Map<string, PrimaryContact>()
    for (let i = 0; i < ids.length; i += 200) {
        const chunk = ids.slice(i, i + 200)
        for (let from = 0; ; from += 1000) {
            const got = mustRows(
                await supabase.from('counterparty_contacts')
                    .select('id, customer_id, name, email, name_inferred')
                    .in('customer_id', chunk)
                    .is('deleted_at', null).eq('is_primary', true)
                    .order('id')
                    .range(from, from + 999),
                'counterparty_contacts') as unknown as (PrimaryContact & { id: string })[]
            for (const r of got) primaryByCustomer.set(r.customer_id, r)
            if (got.length === 0) break
        }
    }

    return customers.map((c) => {
        const p = primaryByCustomer.get(c.id)
        return {
            id: c.id,
            code: c.code,
            legalName: c.legal_name,
            country: c.country,
            contactName: p?.name ?? null,
            contactInferred: Boolean(p?.name_inferred),
            email: p?.email ?? '—',
            types: c.customer_types?.join(', ') ?? '',
            status: c.status,
            // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
            createdLabel: formatAuditStamp(c.created_at),
            createdAt: c.created_at,
            shortName: c.short_name,
            taxId: c.tax_id,
            paymentTerms: c.payment_terms,
            incoterm: c.incoterm,
            creditRating: c.credit_rating,
            address: c.address,
        }
    })
}
