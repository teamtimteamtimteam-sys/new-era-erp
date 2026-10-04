// app/hr/overtime/[id]/page.tsx
// OVERTIME-1:一张加班批 —— 行(谁、哪天、哪一类日子、几个小时)与这一批此刻能做的事。
//
// 【谁在这一页做什么】财务(action.overtime_enter):草稿与被驳回的批上加行 / 删行 · 交去批 · 撤回 · 丢弃 ·
//   冲销一张批过的;仓库(action.overtime_approve):整批批准或驳回(驳回要备注)。
// 【做不了的钮看得见、按不动、说出理由】缺码 → <PermissionGate>(说出码);有码却轮不到你
//   (你交的批 / 批里有你自己)→ 钮按不动,旁边一行说为什么。库里照样按名拒 —— 这一层只是不让人白跑一趟。
// 【行的名字】读 overtime_batch_lines() —— 仓库读不到别人的员工行,那支属主函数只替他打开这一批里那几个人的
//   编号与显示名,不带钱。
import { notFound } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate, formatMonth, toYearMonth, toYmd } from '@/lib/dates'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import BatchDetail, { type LineRow, type StaffOption } from './BatchDetail'
import { OVERTIME_STATUS_CLS } from '../BatchesTable'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'

export default async function OvertimeBatchPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.overtime)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const batches = mustRows(
        await supabase.from('overtime_batches')
            .select('id, label, period_month, status, created_by, submitted_at, submitted_by, decided_at, decided_by, decision_notes, reversed_at, reversed_by, reverse_reason')
            .eq('id', id)
            .limit(1),
        'overtime_batches',
    )
    const batch = batches[0]
    if (!batch) notFound()

    const [lineRes, staffRes, canEnter, canApprove, meRes] = await Promise.all([
        supabase.rpc('overtime_batch_lines', { p_batch_id: id }),
        supabase.rpc('overtime_site_staff'),
        can('action.overtime_enter'),
        can('action.overtime_approve'),
        supabase.rpc('current_user_employee'),
    ])
    const lines = mustRows(lineRes, 'overtime_batch_lines')
    const staff = mustRows(staffRes, 'overtime_site_staff')
    const myEmployeeId = (meRes.data as string | null) ?? null
    // 【认证的三态】(scripts/check-auth-error-swallowing.mjs)这里只用它画一句"这一批是你交的"提示。
    //   问不出来(error)≠ 不是你:那种时候【不画】这句提示 —— 钮照旧按得下,而库里按人认的四眼照旧拒。
    //   一句猜出来的"是你交的"会把一个能批的人挡在门外;一句省掉的提示只让人多走一步、看见库的拒绝。
    const { data: userData, error: userError } = await supabase.auth.getUser()
    const myUserId = userError ? null : (userData.user?.id ?? null)

    const rows: LineRow[] = lines.map((l) => ({
        id: l.line_id,
        employeeId: l.employee_id,
        employeeCode: l.employee_code,
        employeeName: l.employee_name,
        workDate: l.work_date,
        workDateLabel: formatDate(l.work_date, locale),
        dayKind: l.day_kind,
        hours: Number(l.hours),
        note: l.note,
        voided: l.voided,
    }))
    const staffOptions: StaffOption[] = staff.map((s) => ({
        id: s.employee_id, code: s.employee_code, name: s.employee_name,
        hireDate: s.hire_date, separationDate: s.separation_date,
    }))

    // 【轮不到你】两条腿都只是屏幕上的提示 —— 库里按人认(跨账号),这里按这个账号与它的员工档案。
    const iSubmitted = !!myUserId && batch.submitted_by === myUserId
    const iAmInIt = !!myEmployeeId && rows.some((r) => r.employeeId === myEmployeeId && !r.voided)

    // 【这个月的每一天,一个下拉】不是原生日期框(原生日期控件只许减少)。从 1 号正午(UTC)按天往后走,
    //   出了这个月就停 —— 用 lib/dates 的 toYmd / toYearMonth,不自己拼日期。标签按界面语言(formatDate)。
    const batchMonth = toYearMonth(batch.period_month)
    const dayOptions: { value: string; label: string }[] = []
    for (let i = 0, t0 = Date.parse(batchMonth + '-01T12:00:00Z'); i < 31; i++) {
        const ymd = toYmd(new Date(t0 + i * 86_400_000))
        if (toYearMonth(ymd) !== batchMonth) break
        dayOptions.push({ value: ymd, label: formatDate(ymd, locale) })
    }

    const names = await loadActorNames(supabase, [batch.created_by, batch.submitted_by, batch.decided_by, batch.reversed_by])
    const monthLabel = formatMonth(batch.period_month, locale) ?? batch.period_month

    return (
        <div className="p-8 max-w-5xl">
            <Link href="/hr/overtime" className="text-sm hover:underline app-link app-link-inline">
                ← {t('overtime.backToList')}
            </Link>
            <h1 className="mt-2 mb-1 flex flex-wrap items-center gap-3">
                <span>{batch.label}</span>
                <span className={'rounded px-2 py-0.5 text-xs font-normal ' + (OVERTIME_STATUS_CLS[batch.status] ?? 'bg-gray-100 text-gray-600')}>
                    {t('overtime.status_' + batch.status)}
                </span>
            </h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('overtime.batchSubtitle', { month: monthLabel })}</p>

            <dl className="mb-4 grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
                <div className="flex flex-wrap gap-1">
                    <dt className="text-[color:var(--brand-muted-text)]">{t('overtime.createdBy')}</dt>
                    <dd><ActorName userId={batch.created_by} names={names} /></dd>
                </div>
                {batch.submitted_at && (
                    <div className="flex flex-wrap gap-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('overtime.submittedBy')}</dt>
                        <dd><ActorName userId={batch.submitted_by} names={names} /> · {formatAuditStamp(batch.submitted_at)}</dd>
                    </div>
                )}
                {batch.decided_at && (
                    <div className="flex flex-wrap gap-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('overtime.decidedBy')}</dt>
                        <dd><ActorName userId={batch.decided_by} names={names} /> · {formatAuditStamp(batch.decided_at)}</dd>
                    </div>
                )}
                {batch.reversed_at && (
                    <div className="flex flex-wrap gap-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('overtime.reversedBy')}</dt>
                        <dd><ActorName userId={batch.reversed_by} names={names} /> · {formatAuditStamp(batch.reversed_at)}</dd>
                    </div>
                )}
            </dl>
            {batch.status === 'rejected' && batch.decision_notes && (
                <p role="note" className="mb-4 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-900">
                    {t('overtime.rejectedNote', { note: batch.decision_notes })}
                </p>
            )}
            {batch.status === 'reversed' && batch.reverse_reason && (
                <p role="note" className="mb-4 rounded border border-gray-300 bg-gray-50 px-3 py-2 text-sm">
                    {t('overtime.reversedNote', { reason: batch.reverse_reason })}
                </p>
            )}

            <BatchDetail
                batchId={batch.id}
                label={batch.label}
                periodMonth={batch.period_month}
                status={batch.status}
                rows={rows}
                staff={staffOptions}
                dayOptions={dayOptions}
                canEnter={canEnter}
                canApprove={canApprove}
                iSubmitted={iSubmitted}
                iAmInIt={iAmInIt}
            />

            {/* AUDIT-TRAIL-1d-2:页底的审计记录(上面那几行"谁做的"照旧 —— 它是这一批此刻的样子,Q27;记录补上丢弃、
                与被重新送审抹掉的那几次决定)。人名照 ActorName 的规矩:不持 hr.view 的批准人看到的是 Restricted(Q20,已登记) */}
            <AuditTrail subject="overtime_batch" id={batch.id} show={trailCount((await searchParams).trail)} />
        </div>
    )
}
