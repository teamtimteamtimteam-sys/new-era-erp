import 'server-only'

// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):医疗报销登记簿的【一份】读取 —— 页面与导出路由共用。
// 页面只画最新的 CLAIMS_SHOWN 条(从前是一句不说的 .limit(300)),表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取、同一套筛选、同一个映射翻页取全(上限 50,000)。
// ★ Q2 的第二条:状态筛选从前在截断【之后】用 JS 跑(page.tsx 旧 :42 `rows.filter(...)`),于是收窄筛选找不回被截掉的行。
//   现在三条筛选(员工 · 年 · 状态)全部是查询的一部分,在 .range 之前;count 用的是同一套筛选。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { getLocale } from '@/lib/i18n/server'
import { formatDate } from '@/lib/dates'
import type { ClaimRow } from './ClaimsTable'

type Client = SupabaseClient<Database>

/** 页面画多少条 —— 与转换之前同一个数。 */
export const CLAIMS_SHOWN = 300

export type ClaimsFilter = { status?: string; employee?: string; year?: string }

/** 页面与路由读同一份地址栏参数;路由由页面把它们原样拼进 serverRows。 */
export function claimsFilterFrom(sp: URLSearchParams | ClaimsFilter): ClaimsFilter {
    const get = (k: keyof ClaimsFilter) => (sp instanceof URLSearchParams ? sp.get(k) : sp[k]) || undefined
    return { status: get('status'), employee: get('employee'), year: get('year') }
}

export function claimsQuery(f: ClaimsFilter): string {
    const q = new URLSearchParams()
    for (const [k, v] of Object.entries(f)) if (v) q.set(k, v)
    const s = q.toString()
    return s ? `?${s}` : ''
}

type ClaimDbRow = {
    claim_id: string; code: string; employee_code: string; legal_name: string; claim_date: string | null
    amount_sgd: number | string | null; settlement_state: string | null; expense_code: string | null
}

// supabase-js 的查询构造器每加一条筛选换一个类型;筛选写在一处,count 与 page 各用一次
function filtered<Q extends { eq: (c: string, v: string | number) => Q }>(qb: Q, f: ClaimsFilter): Q {
    if (f.employee) qb = qb.eq('employee_id', f.employee)
    if (f.year) qb = qb.eq('claim_year', Number(f.year))
    if (f.status) qb = qb.eq('settlement_state', f.status)
    return qb
}

export function claimsCount(supabase: Client, f: ClaimsFilter) {
    return filtered(supabase.from('medical_claim_status').select('claim_id', { count: 'exact', head: true }), f)
}

export function claimsPage(supabase: Client, f: ClaimsFilter, from: number, to: number) {
    return filtered(supabase.from('medical_claim_status').select('*'), f)
        .order('claim_date', { ascending: false })
        .order('claim_id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as ClaimDbRow[] | null }))
}

export async function shapeClaimRows(rows: ClaimDbRow[]): Promise<ClaimRow[]> {
    const locale = await getLocale()
    return rows.map((r) => ({
        claimId: r.claim_id,
        code: r.code,
        employeeLabel: `${r.employee_code} — ${r.legal_name}`,
        claimDate: r.claim_date ? formatDate(r.claim_date, locale) : '—',
        claimDateRaw: r.claim_date ?? null,
        // U1-A(UNBLOCK-1 Q8):金额对不持 data.view_health 的人(本人的除外)是 null —— 表格印「受限」,不印 0.00
        amountSgd: r.amount_sgd === null ? null : Number(r.amount_sgd).toFixed(2),
        amountSgdRaw: r.amount_sgd,
        settlementState: r.settlement_state ?? '',
        expenseCode: r.expense_code ?? '—',
    }))
}
