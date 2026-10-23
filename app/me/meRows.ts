import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · Q5):/me 上那三张只读最近 50 条的表 —— 请假 · 医疗报销 · 费用报销 ——
// 的【一份】读取,页面与三条导出路由共用。页面照旧画最近 MY_LIST_SHOWN 条,表上方 RowCapNotice 说出「前 N 条,共 M 条」;
// 导出路由按同一条读取翻页取全(上限 50,000)。行的形状与页面交给面板的那一份【逐字相同】(面板用同一份列定义写导出)。
// 读规则不变:全部只读【自己】的行(行级策略 + 属主视图),这里不另加判据;排序之后补唯一键 —— 翻页要一个【唯一】的次序。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { inChunks } from '@/lib/export/serverRows'

type Client = SupabaseClient<Database>

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
export function myLeavePage(supabase: Client, employeeId: string, from: number, to: number) {
    return supabase.from('leave_requests_masked')
        // EMP-SELF-1:decision_notes —— 本人行策略本来就放行这一列(EMP-SELF-0 §1.5 记下的那一处)
        .select('id, code, leave_type_code, start_date, end_date, days, status, created_at, decision_notes')
        .eq('employee_id', employeeId).is('deleted_at', null)
        .order('start_date', { ascending: false }).order('id', { ascending: true })
        .range(from, to)
}

// ── 医疗报销 ──────────────────────────────────────────────────────────────
export function myMedicalCount(supabase: Client, employeeId: string) {
    return supabase.from('medical_claim_status').select('claim_id', { count: 'exact', head: true }).eq('employee_id', employeeId)
}
export function myMedicalPage(supabase: Client, employeeId: string, from: number, to: number) {
    return supabase.from('medical_claim_status').select('*')
        .eq('employee_id', employeeId)
        .order('claim_date', { ascending: false }).order('claim_id', { ascending: true })
        .range(from, to)
}

// ── 费用报销 ──────────────────────────────────────────────────────────────
export function myExpenseCount(supabase: Client, employeeId: string) {
    return supabase.from('expense_claim_status').select('claim_id', { count: 'exact', head: true }).eq('employee_id', employeeId)
}
export function myExpensePage(supabase: Client, employeeId: string, from: number, to: number) {
    return supabase.from('expense_claim_status').select('*')
        .eq('employee_id', employeeId)
        .order('spend_date', { ascending: false }).order('claim_id', { ascending: true })
        .range(from, to)
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
