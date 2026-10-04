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
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'

export default async function AttendancePeriodPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
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
            .select('id, employee_id, note, recorded_at, unpaid_days')
            .eq('period_id', id),
    )
    // ★ OVERTIME-1(Tim Q3):三个加班桶【只读】,来自批过的加班批 —— 已完成的月读冻住的数,
    //   还开着的月读此刻批过的数(overtime_month_hours 一份判据,工资期详情也读它)。
    const otRows = mustRows(
        await supabase.rpc('overtime_month_hours', { p_month: period.period_month as string }),
        'overtime_month_hours',
    )
    const otByEmployee = new Map(otRows.map((o) => [o.employee_id, o]))
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
            normal: Number(otByEmployee.get(l.employee_id)?.weekday_hours ?? 0),
            restDay: Number(otByEmployee.get(l.employee_id)?.rest_day_hours ?? 0),
            holiday: Number(otByEmployee.get(l.employee_id)?.public_holiday_hours ?? 0),
            note: l.note ?? '',
            // ★ 判据是这个戳,不是三个数之和 ★
            recorded: l.recorded_at !== null,
            unpaidDays: l.unpaid_days === null ? null : Number(l.unpaid_days),
        }))
        .sort((a, b) => a.employeeCode.localeCompare(b.employeeCode))

    return (
        <div className="p-8 max-w-5xl">
            <Link href="/hr/attendance" className="text-sm hover:underline app-link app-link-inline">
                ← {t('attendance.backToList')}
            </Link>
            <h1 className="mt-2 mb-1">{period.code}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-1">{t('attendance.subtitle')}</p>
            {period.reopen_reason && (
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">
                    {t('attendance.reopenedFor', { reason: period.reopen_reason })}
                </p>
            )}
            {period.payroll_posted && (
                <p className="mb-4 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-xs text-[color:var(--brand-text)]">
                    {t('attendance.lockedByPayroll')}
                </p>
            )}

            <AttendanceGrid
                periodId={id}
                status={period.status ?? 'open'}
                rows={rows}
            />

            {/* AUDIT-TRAIL-1d-2:页底的审计记录 —— 开月 · 补新人 · 每人一行的记录 · 完成 · 重开(之前那一段只剩最近一次,照直说) */}
            <AuditTrail subject="attendance_period" id={id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
