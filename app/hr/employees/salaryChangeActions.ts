'use server'

// ★ APR-9(Tim 2026-09-27):调薪申请 —— 财务提,CFO 批(CFO 是提单人或主角时 cco 批),批准之前月薪一分不动。
//   提交(module.hr.edit + data.view_pay,不许给自己提)、决定(驳回要理由)、撤回(提单人本人,或持提单那一对码的人)。
//   谁能批这里不预判 —— pay_decision_code 按人路由,读者此刻为什么批不了由 salary_change_requests_visible 说
//   (decide_block),屏幕照着画;拒绝由库出、就地说成人话。
//   生效日【不给默认值】(AGENTS.md「Dates and amounts that decide a period」):空着就拒,两道。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded } from '@/lib/action-refusal'
import { getTranslations } from '@/lib/i18n/server'
import { localizeSalaryChangeError } from './salaryChangeErrorCodes'

export type SalaryChangeState = { error?: string; detail?: string }

function refresh(employeeId: string) {
    revalidatePath(`/hr/employees/${employeeId}`)
    revalidatePath('/hr/employees')
    revalidatePath('/')
}

export async function submitSalaryChange(
    employeeId: string, newSalary: string, effectiveDate: string, reason: string,
): Promise<SalaryChangeState> {
    const t = await getTranslations()
    const n = Number(newSalary)
    if (newSalary.trim() === '' || !Number.isFinite(n) || n < 0) {
        return { error: t('hr.errors.SALARY_AMOUNT_INVALID') }
    }
    if (!effectiveDate) return { error: t('hr.errors.SALARY_EFFECTIVE_DATE_REQUIRED') }
    if (reason.trim() === '') return { error: t('salaryChange.reasonRequired') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('submit_salary_change_request', {
        p_employee_id: employeeId,
        p_new_monthly_salary: n,
        p_effective_date: effectiveDate,
        p_reason: reason.trim(),
    })
    if (error) return await refuseFromCoded(error.message, localizeSalaryChangeError)
    refresh(employeeId)
    return {}
}

export async function decideSalaryChange(
    employeeId: string, requestId: string, approve: boolean, notes: string,
): Promise<SalaryChangeState> {
    if (!approve && notes.trim() === '') {
        return { error: (await getTranslations())('salaryChange.rejectReasonRequired') }
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_salary_change_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes.trim() || undefined,
    })
    if (error) return await refuseFromCoded(error.message, localizeSalaryChangeError)
    refresh(employeeId)
    return {}
}

export async function withdrawSalaryChange(employeeId: string, requestId: string): Promise<SalaryChangeState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_salary_change_request', { p_request_id: requestId })
    if (error) return await refuseFromCoded(error.message, localizeSalaryChangeError)
    refresh(employeeId)
    return {}
}
