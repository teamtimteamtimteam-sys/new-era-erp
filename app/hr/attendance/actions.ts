'use server'

// app/hr/attendance/actions.ts
// ATTEND-1:考勤底稿的五个动作。全部走 DB 函数 —— 拒绝住在函数里,这里只翻译。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeHrError } from '../hrErrorCodes'

export type AttendanceState = { error?: string; success?: boolean; note?: string }

export async function openAttendancePeriod(periodMonth: string): Promise<AttendanceState & { periodId?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('open_attendance_period', {
        p_period_month: periodMonth,
    })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/attendance')
    return { success: true, periodId: (data as { period_id?: string })?.period_id }
}

export async function recordAttendance(
    lineId: string,
    normal: number,
    restDay: number,
    holiday: number,
    note: string | null,
): Promise<AttendanceState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_attendance', {
        p_line_id: lineId,
        p_normal: normal,
        p_rest_day: restDay,
        p_holiday: holiday,
        p_note: note ?? undefined,
    })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/attendance')
    return { success: true }
}

export async function syncAttendancePeriod(periodId: string): Promise<AttendanceState & { added?: number }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('sync_attendance_period', { p_period_id: periodId })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/attendance')
    return { success: true, added: (data as { lines_added?: number })?.lines_added ?? 0 }
}

// ★【拒绝自己把缺口补出来】★
// complete 内部也补名单,但那句 INSERT 与它下面的 RAISE 在【同一条语句】里 ——
// PostgreSQL 会把两者一起回滚。于是"还差 1 行"会指着一行屏幕上根本没有的记录,
// 而操作员无路可走。这里在拒绝【之后】单独调一次 sync:那一行落地、出现在名单里、
// 可以被记录。守卫留在库里(没人调过 sync 也漏不了人),而出路留在这里。
export async function completeAttendancePeriod(periodId: string): Promise<AttendanceState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('complete_attendance_period', { p_period_id: periodId })
    if (!error) {
        revalidatePath('/hr/attendance')
        return { success: true }
    }
    const localized = await localizeHrError(error.message)
    if (error.message.includes('ATTENDANCE_PERIOD_INCOMPLETE')) {
        const synced = await supabase.rpc('sync_attendance_period', { p_period_id: periodId })
        const added = (synced.data as { lines_added?: number })?.lines_added ?? 0
        revalidatePath('/hr/attendance')
        if (added > 0) return { error: localized, note: String(added) }
    }
    return { error: localized }
}

export async function reopenAttendancePeriod(periodId: string, reason: string): Promise<AttendanceState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('reopen_attendance_period', {
        p_period_id: periodId, p_reason: reason,
    })
    if (error) return { error: await localizeHrError(error.message) }
    revalidatePath('/hr/attendance')
    return { success: true }
}
