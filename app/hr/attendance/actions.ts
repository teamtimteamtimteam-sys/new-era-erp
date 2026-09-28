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

// ★ OVERTIME-1(Tim Q3):加班小时不再从这里进来 —— 它们只经批过的加班批,在这个月完成时冻进底稿。
//   这里只记"这一行有人看过了"与一句备注;三个小时参数一律不传(库里默认 0,传非零会按名拒)。
export async function recordAttendance(
    lineId: string,
    note: string | null,
): Promise<AttendanceState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_attendance', {
        p_line_id: lineId,
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
