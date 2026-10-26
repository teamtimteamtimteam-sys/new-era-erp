import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · Q5):/me 上那三张只读最近 50 条的表 —— 请假 · 医疗报销 · 费用报销 ——
// 的【一份】读取,页面与三条导出路由共用。页面照旧画最近 MY_LIST_SHOWN 条,表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取翻页取全(上限 50,000)。行的形状与页面交给面板的那一份【逐字相同】(面板用同一份列定义写导出)。
// 读规则不变:全部只读【自己】的行(行级策略 + 属主视图),这里不另加判据;排序之后补唯一键 —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { inChunks } from '@/lib/export/serverRows'
import { parseListSort, applyListSort, setSortParams, type ListSort } from '@/lib/listSort'
import { mustRows } from '@/lib/db-helpers'
import { shapeListTotals, type ListTotal } from '@/lib/listTotals'

type Client = SupabaseClient<Database>

// ── TABLE-FEATURES-1(Tim 2026-10-25 Q9):三张表都只画最近 50 条,所以在数据库里排 ────────────────────────────
// 一页上三张在数据库里排的表 → 各用一个参数前缀(lib/listSort.ts 规矩 ⑥):请假 `leave_`、医疗 `mc_`、费用 `exp_`。
// 白名单 = 列键 → 那张表读的关系上的列。假别名是从 leave_types 查出来的、「决定」来自 my_document_decisions()、
// 费用报销的「说明」是用途与逐笔拼出来的 —— 都不可排。费用报销的金额是各单自己的币种、视图上没有本位币金额 → 不可排(规矩 ⑤)。
// 默认与今天一样(各自的日期新的在前),平局键照旧。
export const MY_LEAVE_SORT = { code: 'code', dates: 'start_date', days: 'days', status: 'status' } as const
export const MY_MEDICAL_SORT = { code: 'code', date: 'claim_date', amount: 'amount_sgd', state: 'settlement_state' } as const
export const MY_EXPENSE_SORT = { ref: 'code', spent: 'spend_date', status: 'status' } as const
export type MyLeaveSortKey = keyof typeof MY_LEAVE_SORT
export type MyMedicalSortKey = keyof typeof MY_MEDICAL_SORT
export type MyExpenseSortKey = keyof typeof MY_EXPENSE_SORT
export const MY_SORT_PREFIX = { leave: 'leave_', medical: 'mc_', expense: 'exp_' } as const

type Search = Record<string, string | string[] | undefined>
export const parseMyLeaveSort = (sp: Search) =>
    parseListSort(sp, Object.keys(MY_LEAVE_SORT) as MyLeaveSortKey[], { key: 'dates', dir: 'desc' }, MY_SORT_PREFIX.leave)
export const parseMyMedicalSort = (sp: Search) =>
    parseListSort(sp, Object.keys(MY_MEDICAL_SORT) as MyMedicalSortKey[], { key: 'date', dir: 'desc' }, MY_SORT_PREFIX.medical)
export const parseMyExpenseSort = (sp: Search) =>
    parseListSort(sp, Object.keys(MY_EXPENSE_SORT) as MyExpenseSortKey[], { key: 'spent', dir: 'desc' }, MY_SORT_PREFIX.expense)

/** 三条导出路由的地址:带上那张表自己的顺序(同一个前缀),导出按当前顺序取全。 */
export function myExportHref(path: string, sort: ListSort, prefix: string): string {
    return `${path}?${setSortParams(new URLSearchParams(), sort, prefix).toString()}`
}

/** 页面画多少条 —— 与转换之前同一个数。 */
export const MY_LIST_SHOWN = 50

/** 当前登录的人是哪一位员工(my_profile 只回自己那一行);不是员工 → null。 */
export async function myEmployeeId(supabase: Client): Promise<string | null> {
    const { data, error } = await supabase.from('my_profile').select('employee_id').limit(1)
    if (error) throw new Error(`EXPORT_READ_FAILED|my_profile|${error.message}`)
    return (data?.[0]?.employee_id as string | null | undefined) ?? null
}

// ── 请假 ──────────────────────────────────────────────────────────────────
// U1-A(UNBLOCK-1 Q8):leave_requests 有了遮蔽伴生视图,读它(这几列对本人原样)
export function myLeaveCount(supabase: Client, employeeId: string) {
    return supabase.from('leave_requests_masked').select('id', { count: 'exact', head: true })
        .eq('employee_id', employeeId).is('deleted_at', null)
}
export function myLeavePage(supabase: Client, employeeId: string, sort: ListSort<MyLeaveSortKey>, from: number, to: number) {
    return applyListSort(supabase.from('leave_requests_masked')
        // EMP-SELF-1:decision_notes —— 本人行策略本来就放行这一列(EMP-SELF-0 §1.5 记下的那一处)
        .select('id, code, leave_type_code, start_date, end_date, days, status, created_at, decision_notes')
        .eq('employee_id', employeeId).is('deleted_at', null),
        // TABLE-FEATURES-1 Q9:ORDER BY 在 .range(截断)之前
        sort, MY_LEAVE_SORT, [['start_date', 'desc'], ['id', 'asc']])
        .range(from, to)
}

// ── 医疗报销 ──────────────────────────────────────────────────────────────
export function myMedicalCount(supabase: Client, employeeId: string) {
    return supabase.from('medical_claim_status').select('claim_id', { count: 'exact', head: true }).eq('employee_id', employeeId)
}
export function myMedicalPage(supabase: Client, employeeId: string, sort: ListSort<MyMedicalSortKey>, from: number, to: number) {
    return applyListSort(supabase.from('medical_claim_status').select('*')
        .eq('employee_id', employeeId),
        // TABLE-FEATURES-1 Q9:ORDER BY 在 .range(截断)之前
        sort, MY_MEDICAL_SORT, [['claim_date', 'desc'], ['claim_id', 'asc']])
        .range(from, to)
}

// ── 费用报销 ──────────────────────────────────────────────────────────────
export function myExpenseCount(supabase: Client, employeeId: string) {
    return supabase.from('expense_claim_status').select('claim_id', { count: 'exact', head: true }).eq('employee_id', employeeId)
}
export function myExpensePage(supabase: Client, employeeId: string, sort: ListSort<MyExpenseSortKey>, from: number, to: number) {
    return applyListSort(supabase.from('expense_claim_status').select('*')
        .eq('employee_id', employeeId),
        // TABLE-FEATURES-1 Q9:ORDER BY 在 .range(截断)之前
        sort, MY_EXPENSE_SORT, [['spend_date', 'desc'], ['claim_id', 'asc']])
        .range(from, to)
}

// ── TABLE-FEATURES-2(Tim 2026-10-25 Q1):三张金额表的表尾合计 ─────────────────────────────────────────
// 由库算、覆盖【全部】自己的行(医疗与费用两张只画最近 MY_LIST_SHOWN 条)。三支都没有参数:主语就是调用者
// (current_user_employee()),与上面的 .eq('employee_id') 同一个人;不是员工的调用按名拒(本页对他不画这几张表)。
// 工资单那一支是 DEFINER —— 币种住在只给 hr.view 的 payroll_periods 上(与 my_period_labels 同一个理由)。
export async function myPayslipTotals(supabase: Client): Promise<ListTotal[]> {
    return shapeListTotals(mustRows(await supabase.rpc('list_totals_my_payslips'), 'my payslip totals'))
}
export async function myMedicalTotals(supabase: Client): Promise<ListTotal[]> {
    return shapeListTotals(mustRows(await supabase.rpc('list_totals_my_medical_claims'), 'my medical claim totals'))
}
export async function myExpenseTotals(supabase: Client): Promise<ListTotal[]> {
    return shapeListTotals(mustRows(await supabase.rpc('list_totals_my_expense_claims'), 'my expense claim totals'))
}

type ItemDb = { id: string; claim_id: string; line_no: number; spend_date: string; amount_ccy: number; description: string; no_receipt_reason: string | null }

/**
 * ★ EXPENSE-MULTILINE-1:每张单的明细按单挂上来(明细表的读规则与表头同一条);
 * ★ CLAIM-RECEIPTS-1:每一笔有没有 attached 的收据 —— 导出的「说明」一格要说出它(页面另把收据清单交给面板,
 *   导出取到的单可能不在那 50 张里,所以这里给每一笔带上 `has_receipt`)。
 */
export async function attachMyExpenseItems<H extends { claim_id: string }>(supabase: Client, headers: H[]) {
    const ids = headers.map((h) => h.claim_id)
    const [items, receipts] = await Promise.all([
        inChunks(ids, (c) => supabase.from('expense_claim_items')
            .select('id, claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason')
            .in('claim_id', c).order('line_no')
            .then(({ data, error }) => ({ error, data: data as ItemDb[] | null })), 'expense_claim_items (me)'),
        inChunks(ids, (c) => supabase.from('expense_claim_receipts').select('item_id')
            .in('claim_id', c).eq('status', 'attached')
            .then(({ data, error }) => ({ error, data: data as { item_id: string }[] | null })), 'expense_claim_receipts (me)'),
    ])
    const withReceipt = new Set(receipts.map((r) => r.item_id))
    return headers.map((h) => ({
        ...h,
        items: items.filter((i) => i.claim_id === h.claim_id).sort((a, b) => a.line_no - b.line_no)
            .map((i) => ({ ...i, has_receipt: withReceipt.has(i.id) })),
    }))
}
