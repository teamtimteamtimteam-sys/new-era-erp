// app/hr/payroll/loadGridData.ts
// 录入表格要的两样东西:在职员工名单,以及【上一期】各人的数字(用于预填)。
// 新建与编辑两个页面共用 —— 预填口径只有一份定义。
// 普通模块(非 server action),由服务端页面调用。
import type { createClient } from '@/lib/supabase/server'
import type { PayrollLineInput } from './actions'
import type { EmployeeRow } from './PayrollGrid'
import { mustRows } from '@/lib/db-helpers'

type ServerSupabase = Awaited<ReturnType<typeof createClient>>

export async function loadGridData(
    supabase: ServerSupabase,
    opts: { beforeMonth?: string; currentPeriodId?: string }
): Promise<{ employees: EmployeeRow[]; prefill: Record<string, Partial<PayrollLineInput>>; hasPrefill: boolean }> {
    // 在职员工(已离职的不出现在录入表里 —— 他们当月本来就不该有工资行;
    // 真有末月工资的情况,先把状态改回去或直接在离职当月录完再改状态)
    const { data: empRows } = await supabase
        .from('employees')
        .select('id, code, legal_name')
        .is('deleted_at', null)
        .neq('employment_status', 'separated')
        .order('code')
    const employees: EmployeeRow[] = (empRows ?? []).map((e) => ({
        id: e.id,
        code: e.code,
        legal_name: e.legal_name,
    }))

    // 预填来源:编辑现有期间时用它自己的明细;新建时用上一期
    let sourcePeriodId: string | null = null
    if (opts.currentPeriodId) {
        sourcePeriodId = opts.currentPeriodId
    } else {
        let q = supabase
            .from('payroll_periods')
            .select('id, period_month')
            .is('deleted_at', null)
            .order('period_month', { ascending: false })
            .limit(1)
        if (opts.beforeMonth) q = q.lt('period_month', opts.beforeMonth)
        const { data: prev } = await q
        sourcePeriodId = prev?.[0]?.id ?? null
    }

    const prefill: Record<string, Partial<PayrollLineInput>> = {}
    if (sourcePeriodId) {
        // 【读不到就必须炸】编辑现有期间时这就是当期明细。读成空集 → 表格全空 →
        // 保存走 upsert_payroll_period(先 DELETE payroll_lines 再按非空行重插)
        // → 整月工资被抹掉。读不到当前状态的表单不许提供写入。
        const linesRes = await supabase
            .from('payroll_lines_masked')
            .select('employee_id, gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay')
            .eq('payroll_period_id', sourcePeriodId)
        for (const l of mustRows(linesRes, 'payroll_lines_masked prefill')) {
            // cut 2b:没有 data.view_pay 时金额回来是 null。【不能】String(null) ——
            // 那会把 "null" 填进表单格子里。看不见上期金额的人,格子就留空。
            if (l.employee_id === null || l.gross_pay === null) continue
            prefill[l.employee_id] = {
                gross_pay: String(l.gross_pay),
                employer_cpf: String(l.employer_cpf),
                employee_cpf: String(l.employee_cpf),
                other_deductions: String(l.other_deductions),
                net_pay: String(l.net_pay),
            }
        }
    }

    // 编辑自己的明细不算"上月预填",不必挂那条提醒
    const hasPrefill = !opts.currentPeriodId && Object.keys(prefill).length > 0
    return { employees, prefill, hasPrefill }
}
