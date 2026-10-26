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
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'

type Client = SupabaseClient<Database>

/**
 * ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9):可排的列 —— 列键 → `medical_claim_status` 上的列(lib/listSort.ts 的规矩)。
 *   金额按视图上那一列排:不持 data.view_health 的读者在那里是 NULL,排在最后,不泄露大小(规矩 ②)。
 *   员工那一格是「工号 — 姓名」拼出来的,不可排。默认与今天一样:报销日新的在前,平局按 claim_id。
 */
export const CLAIMS_SORT = { code: 'code', date: 'claim_date', amount: 'amount_sgd', state: 'settlement_state', expense: 'expense_code' } as const
export type ClaimsSortKey = keyof typeof CLAIMS_SORT
const CLAIMS_SORT_DEFAULT: ListSort<ClaimsSortKey> = { key: 'date', dir: 'desc' }

/** 页面画多少条 —— 与转换之前同一个数。 */
export const CLAIMS_SHOWN = 300

export type ClaimsFilter = { status?: string; employee?: string; year?: string; sort: ListSort<ClaimsSortKey> }

type ClaimsSearch = { status?: string; employee?: string; year?: string; sort?: string; dir?: string }

/** 页面与路由读同一份地址栏参数;路由由页面把它们原样拼进 serverRows。 */
export function claimsFilterFrom(sp: URLSearchParams | ClaimsSearch): ClaimsFilter {
    const get = (k: keyof ClaimsSearch) => (sp instanceof URLSearchParams ? sp.get(k) : sp[k]) || undefined
    return {
        status: get('status'), employee: get('employee'), year: get('year'),
        // TABLE-FEATURES-1 Q9:排序与筛选读同一份参数
        sort: parseListSort({ sort: get('sort'), dir: get('dir') }, Object.keys(CLAIMS_SORT) as ClaimsSortKey[], CLAIMS_SORT_DEFAULT),
    }
}

export function claimsQuery(f: ClaimsFilter): string {
    const q = new URLSearchParams()
    if (f.status) q.set('status', f.status)
    if (f.employee) q.set('employee', f.employee)
    if (f.year) q.set('year', f.year)
    // TABLE-FEATURES-1 Q9:导出按当前顺序取全
    setSortParams(q, f.sort)
    return `?${q.toString()}`
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

/**
 * ★ TABLE-FEATURES-2(Tim 2026-10-25 Q1):表尾合计 —— 所有符合筛选的行(不只是画出来的前 CLAIMS_SHOWN 条),由库算
 *   (list_totals_medical_claims)。筛选与 filtered() 同一套参数;别人的金额对读者遮着时读「受限」。
 */
export async function claimsTotals(supabase: Client, f: ClaimsFilter): Promise<ListTotal[]> {
    const args = { p_employee: f.employee || undefined, p_year: f.year ? Number(f.year) : undefined, p_status: f.status || undefined }
    const res = await supabase.rpc('list_totals_medical_claims', args)
    return shapeListTotals(mustRows(res, 'medical claims totals'))
}

export function claimsCount(supabase: Client, f: ClaimsFilter) {
    return filtered(supabase.from('medical_claim_status').select('claim_id', { count: 'exact', head: true }), f)
}

export function claimsPage(supabase: Client, f: ClaimsFilter, from: number, to: number) {
    // TABLE-FEATURES-1 Q9:ORDER BY 在 .range(截断)之前 —— 「前 300 条」是按读者选的顺序取的前 300 条
    return applyListSort(filtered(supabase.from('medical_claim_status').select('*'), f), f.sort, CLAIMS_SORT, [['claim_date', 'desc'], ['claim_id', 'asc']])
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
