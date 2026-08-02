'use server'

// app/hr/leave/actions.ts
// 请假的写入口。全部走 HR-2a/2b 的 SECURITY DEFINER 函数 ——
// 余额检查、先用旧的消耗、例外守卫都长在函数里,界面不复制这些规则。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'

export type LeaveState = { error?: string; success?: boolean; code?: string }

// DB 的错误码 → 人话。看到 INSUFFICIENT_BALANCE 的人要的是"还剩几天、你要几天",
// 不是一串大写字母。
export async function localizeLeaveError(message: string): Promise<string> {
    const t = await getTranslations()
    const m = (message ?? '').trim().match(/([A-Z_]+)(?:\|(.*))?$/)
    if (!m) return message
    const p = (m[2] ?? '').split('|')
    switch (m[1]) {
        case 'INSUFFICIENT_ACCRUED_LEAVE':
        case 'INSUFFICIENT_BALANCE':
            return t('leave.errInsufficient', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'PROBATION_NO_ANNUAL_LEAVE':
            return t('leave.errProbation')
        case 'OVERLAPPING_REQUEST':
            return t('leave.errOverlap', { 0: p[0] ?? '' })
        case 'CERTIFICATE_REQUIRED':
            return t('leave.errCertificate', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'EXCEPTION_REASON_REQUIRED':
            return t('leave.errExceptionReason')
        case 'EXCEPTION_DAYS_INVALID':
            return t('leave.errExceptionDays')
        case 'NO_WORKING_DAYS':
            return t('leave.errNoWorkingDays')
        case 'GRANT_EXISTS':
            return t('leave.errGrantExists', { 0: p[0] ?? '' })
        case 'CARRY_FORWARD_EXISTS':
            return t('leave.errCarryExists', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'REQUEST_NOT_PENDING':
            return t('leave.errNotPending', { 0: p[0] ?? '' })
        case 'PERMISSION_DENIED':
            return t('permissions.errDenied')
        case 'CLAIM_NOT_APPROVED':
            return t('claims.errNotApproved', { 0: p[0] ?? '' })
        case 'CLAIM_ALREADY_PAID':
            return t('claims.errAlreadyPaid', { 0: p[0] ?? '' })
        case 'CLAIM_EXCEEDS_LIMIT':
            return t('claims.errExceedsLimit', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'SUPPLIER_REQUIRED_FOR_UNPAID':
            return t('claims.errSupplierRequired')
        case 'FX_RATE_MISSING':
            return t('claims.errFxMissing', { 0: p[1] ?? '' })
        default:
            return message
    }
}

export async function submitLeave(form: {
    employeeId: string
    leaveTypeCode: string
    start: string
    end: string
    startHalf: boolean
    endHalf: boolean
    reason: string | null
    certificateRef: string | null
    isException?: boolean
    exceptionDays?: number | null
    exceptionReason?: string | null
}): Promise<LeaveState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_leave_request', {
        p_employee_id: form.employeeId,
        p_leave_type_code: form.leaveTypeCode,
        p_start: form.start,
        p_end: form.end,
        p_start_half: form.startHalf,
        p_end_half: form.endHalf,
        p_reason: form.reason ?? undefined,
        p_certificate_ref: form.certificateRef ?? undefined,
        p_is_exception: form.isException ?? false,
        p_exception_days: form.exceptionDays ?? undefined,
        p_exception_reason: form.exceptionReason ?? undefined,
    })
    if (error) {
        // 【"不够"必须说得出"什么时候够"】否则员工只能去问 HR,而那件事系统自己知道。
        // 日期由 annual_leave_available_from 算 —— 累积规则只有一份实现,不在这里重写。
        const m = (error.message ?? '').trim().match(/^INSUFFICIENT_ACCRUED_LEAVE\|([^|]*)\|([^|]*)$/)
        if (m) {
            const t = await getTranslations()
            const { data: from } = await supabase.rpc('annual_leave_available_from', {
                p_employee_id: form.employeeId,
                p_days: Number(m[2]),
                p_from: form.start,
            })
            return {
                error: from
                    ? t('leave.errInsufficientFrom', { 0: m[1], 1: m[2], 2: String(from) })
                    : t('leave.errInsufficientNever', { 0: m[1], 1: m[2] }),
            }
        }
        return { error: await localizeLeaveError(error.message) }
    }
    revalidatePath('/hr/leave')
    revalidatePath('/me')
    return { success: true, code: (data as { code?: string })?.code }
}

export async function decideLeave(
    requestId: string,
    approve: boolean,
    notes: string | null
): Promise<LeaveState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('decide_leave_request', {
        p_request_id: requestId,
        p_approve: approve,
        p_notes: notes ?? undefined,
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/leave')
    return { success: true }
}

export async function cancelLeave(requestId: string, reason: string | null): Promise<LeaveState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_leave_request', {
        p_request_id: requestId,
        p_reason: reason ?? undefined,
    })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/leave')
    revalidatePath('/me')
    return { success: true }
}

// 服务端算天数,供表单实时显示 —— 【与提交时用的是同一个 DB 函数】,
// 所以"预览说几天"和"实际记几天"不可能不一致。
export async function previewLeaveDays(
    start: string,
    end: string,
    startHalf: boolean,
    endHalf: boolean
): Promise<number | null> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('calculate_leave_days', {
        p_start: start,
        p_end: end,
        p_start_half: startHalf,
        p_end_half: endHalf,
    })
    if (error) return null
    return data as number
}

// grant_annual_leave 已随 HR-2c 删除:年假按月累积、读时派生,没有"整年发放"这个动作了。年末结转仍在下面,那是另一个来源。
export async function runCarryForward(year: number): Promise<LeaveState & { detail?: unknown }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('carry_forward_annual_leave', { p_leave_year: year })
    if (error) return { error: await localizeLeaveError(error.message) }
    revalidatePath('/hr/leave/grants')
    return { success: true, detail: data }
}
