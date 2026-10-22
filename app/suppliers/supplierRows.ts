import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):供应商名单的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两行不再随机互换)。
//
// ★ Q5 / Q11:旧的 CSV 导出比表多六列(简称 · 税号 · 付款条件 · 贸易术语 · 信用评级 · 地址)。
//   它们作为表【声明】的扩展列留在导出里(SuppliersTable 的 exportSpec.extension),
//   所以原始值要在这一份行上 —— select 里多读那几列,页面不画它们。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatAuditStamp } from '@/lib/dates'
import { applySupplierFilters, type SupplierListParams } from './supplierQuery'
import type { SupplierTableRow } from './SuppliersTable'

type Client = SupabaseClient<Database>

export const SUPPLIER_LIST_SELECT =
    'id, code, legal_name, short_name, country, supplier_types, status, tax_id, payment_terms, incoterm, credit_rating, address, created_at'

export function supplierCount(supabase: Client, params: SupplierListParams) {
    return applySupplierFilters(
        supabase.from('suppliers').select('id', { count: 'exact', head: true }).neq('counterparty_type', 'forwarder'),
        params,
    )
}

export function supplierPage(supabase: Client, params: SupplierListParams, from: number, to: number) {
    return applySupplierFilters(
        supabase
            .from('suppliers')
            .select(SUPPLIER_LIST_SELECT)
            // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
            .neq('counterparty_type', 'forwarder'),
        params,
    )
        .order('id', { ascending: true })
        .range(from, to)
}

type SupplierDbRow = NonNullable<Awaited<ReturnType<typeof supplierPage>>['data']>[number]

export function shapeSupplierRows(suppliers: SupplierDbRow[]): SupplierTableRow[] {
    return suppliers.map((s) => ({
        id: s.id,
        code: s.code,
        legalName: s.legal_name,
        country: s.country,
        types: s.supplier_types?.join(', ') ?? '',
        status: s.status,
        // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
        createdLabel: formatAuditStamp(s.created_at),
        createdAt: s.created_at,
        shortName: s.short_name,
        taxId: s.tax_id,
        paymentTerms: s.payment_terms,
        incoterm: s.incoterm,
        creditRating: s.credit_rating,
        address: s.address,
    }))
}
