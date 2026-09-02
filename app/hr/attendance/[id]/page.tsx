// app/hr/attendance/[id]/page.tsx
// ATTEND-1:一个月的底稿 —— 每人一行。
import { notFound } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import AttendanceGrid from './AttendanceGrid'

export default async function AttendancePeriodPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: statusRows } = await supabase
        .from('attendance_period_status')
        .select('period_id, code, period_month, status, line_count, unrecorded_count, unpaid_days, payroll_posted, reopen_reason')
        .eq('period_id', id)
        .limit(1)
    const period = statusRows?.[0]
    if (!period) notFound()

    const lines = mustRows(
        await supabase
            .from('attendance_lines')
            .select('id, employee_id, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, note, recorded_at, unpaid_days')
            .eq('period_id', id),
    )
    const empIds = lines.map((l) => l.employee_id)
    // 【读 employees_masked,不是 employees】这一页只要工号与姓名,但薪酬列
    // 就在同一张表上 —— 遮蔽视图按权限把它们呈现为 null,而直连表会让整条查询
    // 42501。check-masked-reads 抓到了第一版,而它抓得对。
    const emps = empIds.length
        ? mustRows(await supabase.from('employees_masked').select('id, code, legal_name').in('id', empIds))
        : []
    const empById = new Map(emps.map((e) => [e.id, e]))

    const rows = lines
        .map((l) => ({
            lineId: l.id,
            employeeCode: empById.get(l.employee_id)?.code ?? '—',
            legalName: empById.get(l.employee_id)?.legal_name ?? '—',
            normal: Number(l.ot_normal_hours ?? 0),
            restDay: Number(l.ot_rest_day_hours ?? 0),
            holiday: Number(l.ot_public_holiday_hours ?? 0),
            note: l.note ?? '',
            // ★ 判据是这个戳,不是三个数之和 ★
            recorded: l.recorded_at !== null,
            unpaidDays: l.unpaid_days === null ? null : Number(l.unpaid_days),
        }))
        .sort((a, b) => a.employeeCode.localeCompare(b.employeeCode))

    return (
        <div className="p-8 max-w-5xl">
            <Link href="/hr/attendance" className="text-sm text-blue-600 hover:underline">
                ← {t('attendance.backToList')}
            </Link>
            <h1 className="text-2xl font-bold mt-2 mb-1">{period.code}</h1>
            <p className="text-sm text-gray-500 mb-1">{t('attendance.subtitle')}</p>
            {period.reopen_reason && (
                <p className="text-xs text-gray-500 mb-1">
                    {t('attendance.reopenedFor', { reason: period.reopen_reason })}
                </p>
            )}
            {period.payroll_posted && (
                <p className="mb-4 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-xs text-gray-700">
                    {t('attendance.lockedByPayroll')}
                </p>
            )}

            <AttendanceGrid
                periodId={id}
                status={period.status ?? 'open'}
                rows={rows}
            />
        </div>
    )
}
