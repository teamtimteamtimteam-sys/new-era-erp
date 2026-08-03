// app/hr/employees/[id]/page.tsx
// 员工档案:资料卡 → 任职履历(时间线)→ 培训记录 → 薪资历史。
// 薪资一栏是【本人】的逐月数字,属受限内容,页面上明说。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoney } from '@/lib/format'
import Subnav from '../../Subnav'
import { statusPillClass } from '../../reviews/reviewShared'

export default async function EmployeeDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const { data: emp, error } = await supabase
        .from('employees_masked')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !emp) {
        notFound()
    }

    const [dirRes, deptRes, mgrRes, historyRes, trainingRes, payRes] = await Promise.all([
        supabase
            .from('employee_directory')
            .select('days_to_work_pass_expiry, work_pass_alert, training_count')
            .eq('employee_id', id)
            .maybeSingle(),
        emp.department_id
            ? supabase.from('departments').select('code, name_en, name_zh').eq('id', emp.department_id).single()
            : Promise.resolve({ data: null }),
        emp.manager_id
            ? supabase.from('employees').select('id, code, legal_name').eq('id', emp.manager_id).single()
            : Promise.resolve({ data: null }),
        supabase
            .from('employment_history')
            .select('id, effective_date, change_type, job_title, department_id, employment_type, employment_status, notes')
            .eq('employee_id', id)
            .order('effective_date', { ascending: false })
            .order('created_at', { ascending: false }),
        supabase
            .from('training_records')
            .select('id, training_name, category, completed_date, expiry_date, provider, certificate_ref')
            .eq('employee_id', id)
            .is('deleted_at', null)
            .order('completed_date', { ascending: false }),
        supabase
            .from('payroll_lines_masked')
            .select('id, gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay, payroll_periods(id, code, period_month, currency, status)')
            .eq('employee_id', id),
    ])

    // 绩效评估(HR-3d):没有 module.hr.view + data.view_reviews 的读者在这里是零行,
    // 整节隐去 —— 一个空表头对读不到内容的人只是噪音。
    const [empReviewsRes, ratingScaleRes] = await Promise.all([
        supabase
            .from('performance_reviews_masked')
            .select('id, review_type, cycle_id, period_start, period_end, status, rating_code')
            .eq('employee_id', id)
            .order('period_end', { ascending: false }),
        supabase.from('review_rating_scale').select('code, name_en, name_zh'),
    ])
    type EmpReview = {
        id: string
        review_type: string
        cycle_id: string | null
        period_start: string
        period_end: string
        status: string
        rating_code: string | null
    }
    const empReviews = (empReviewsRes.data as unknown as EmpReview[] | null) ?? []
    const cycleIds = Array.from(new Set(empReviews.map((r) => r.cycle_id).filter((x): x is string => x !== null)))
    const { data: reviewCycles } = cycleIds.length
        ? await supabase.from('review_cycles').select('id, name').in('id', cycleIds)
        : { data: [] as { id: string; name: string }[] }
    const reviewCycleById = new Map((reviewCycles ?? []).map((c) => [c.id, c.name]))
    const ratingNameByCode = new Map(
        ((ratingScaleRes.data ?? []) as { code: string; name_en: string; name_zh: string }[]).map((s) => [
            s.code,
            locale === 'zh' ? s.name_zh : s.name_en,
        ])
    )

    const dir = dirRes.data
    const history = historyRes.data ?? []
    const training = trainingRes.data ?? []
    type PayRow = {
        id: string
        gross_pay: number
        employer_cpf: number
        employee_cpf: number
        other_deductions: number
        net_pay: number
        payroll_periods: { id: string; code: string; period_month: string; currency: string; status: string } | null
    }
    const payroll = ((payRes.data as unknown as PayRow[] | null) ?? []).sort((a, b) =>
        (b.payroll_periods?.period_month ?? '').localeCompare(a.payroll_periods?.period_month ?? '')
    )

    // 履历里的部门 id → 编号
    const histDeptIds = Array.from(new Set(history.map((h) => h.department_id).filter(Boolean))) as string[]
    const { data: histDepts } = histDeptIds.length
        ? await supabase.from('departments').select('id, code').in('id', histDeptIds)
        : { data: [] as { id: string; code: string }[] }
    const deptCodeById = new Map((histDepts ?? []).map((d) => [d.id, d.code]))

    const deptLabel = deptRes.data
        ? `${deptRes.data.code} — ${locale === 'zh' ? deptRes.data.name_zh : deptRes.data.name_en}`
        : '—'

    const today = new Date().toISOString().slice(0, 10)

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/hr/employees" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-center mb-2">
                <h1 className="text-2xl font-bold">
                    {emp.legal_name}
                    <span className="ml-3 font-mono text-base text-gray-500">{emp.code}</span>
                </h1>
                <div className="flex items-center gap-3">
                    <Link
                        href={`/hr/training/new?employee=${id}`}
                        className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
                    >
                        {t('hr.recordTraining')}
                    </Link>
                    <Link
                        href={`/hr/employees/${id}/edit`}
                        className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm"
                    >
                        {t('purchasing.editLink')}
                    </Link>
                </div>
            </div>

            <Subnav />

            {/* 资料卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 grid gap-x-8 gap-y-2 text-sm sm:grid-cols-2">
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colDepartment')}:</span>
                    {deptLabel}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colJobTitle')}:</span>
                    {emp.job_title ?? '—'}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colManager')}:</span>
                    {mgrRes.data ? (
                        <Link href={`/hr/employees/${mgrRes.data.id}`} className="text-blue-600 hover:underline">
                            {mgrRes.data.code} — {mgrRes.data.legal_name}
                        </Link>
                    ) : (
                        '—'
                    )}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colEmploymentType')}:</span>
                    {t('hr.employmentType.' + emp.employment_type)}
                    <span className="mx-2 text-gray-300">·</span>
                    {t('hr.workCategory.' + emp.work_category)}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colStatus')}:</span>
                    {t('hr.employmentStatus.' + emp.employment_status)}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colHireDate')}:</span>
                    {emp.hire_date}
                    {emp.probation_end_date && (
                        <span className="text-gray-500 ml-2">
                            {t('hr.colProbationEnd')}: {emp.probation_end_date}
                        </span>
                    )}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colAnnualLeaveAvailable')}:</span>
                    <span className="font-mono">{emp.annual_leave_available_days ?? '-'}</span>
                    <span className="text-xs text-gray-500 ml-1">{t('hr.unitDays')}</span>
                    <span className="text-gray-600 ml-4 mr-1">{t('hr.colAnnualLeaveAccrued')}:</span>
                    <span className="font-mono">{emp.annual_leave_accrued_days ?? '-'}</span>
                    <span className="text-xs text-gray-500 ml-1">{t('hr.unitDays')}</span>
                    <span className="text-gray-600 ml-4 mr-1">{t('hr.colAnnualLeaveRate')}:</span>
                    <span className="font-mono">{emp.annual_leave_rate_days ?? '-'}</span>
                    <span className="text-xs text-gray-500 ml-1">{t('hr.unitDaysPerYear')}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colResidency')}:</span>
                    {emp.residency_status ? t('hr.residency.' + emp.residency_status) : '—'}
                    {emp.work_pass_type && (
                        <span className="ml-2">
                            {emp.work_pass_type} · {emp.work_pass_expiry_date}
                            {dir?.work_pass_alert && (
                                <span
                                    className={
                                        'ml-2 px-1.5 py-0.5 rounded text-xs ' +
                                        (dir.work_pass_alert === 'expired'
                                            ? 'bg-red-100 text-red-800'
                                            : dir.work_pass_alert === 'critical'
                                              ? 'bg-amber-100 text-amber-800'
                                              : 'bg-gray-200 text-gray-600')
                                    }
                                >
                                    {t('hr.severity.' + dir.work_pass_alert)}
                                </span>
                            )}
                        </span>
                    )}
                </div>
                {emp.employment_status === 'separated' && (
                    <div className="sm:col-span-2 text-gray-700">
                        <span className="text-gray-600 mr-1">{t('hr.colSeparationDate')}:</span>
                        {emp.separation_date ?? '—'}
                        {emp.separation_type && (
                            <span className="ml-2">{t('hr.separationType.' + emp.separation_type)}</span>
                        )}
                        {emp.separation_notes && <span className="ml-2 text-gray-500">{emp.separation_notes}</span>}
                    </div>
                )}
            </div>

            {emp.notes && (
                <p className="text-sm text-gray-600 mb-6 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('hr.colNotes')}:</span>
                    {emp.notes}
                </p>
            )}

            {/* 任职履历 */}
            <h2 className="text-xl font-bold mb-3">{t('hr.historyTitle')}</h2>
            {history.length === 0 ? (
                <p className="text-sm text-gray-500 mb-6">{t('hr.historyEmpty')}</p>
            ) : (
                <ol className="mb-6 border-l-2 border-gray-200 pl-4 space-y-3">
                    {history.map((h) => (
                        <li key={h.id} className="text-sm">
                            <div className="flex flex-wrap items-baseline gap-2">
                                <span className="font-mono text-gray-600">{h.effective_date}</span>
                                <span className="px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-700">
                                    {t('hr.changeType.' + h.change_type)}
                                </span>
                                {h.job_title && <span>{h.job_title}</span>}
                                {h.department_id && (
                                    <span className="text-gray-500">
                                        {deptCodeById.get(h.department_id) ?? ''}
                                    </span>
                                )}
                            </div>
                            {h.notes && <p className="text-gray-500 mt-0.5">{h.notes}</p>}
                        </li>
                    ))}
                </ol>
            )}

            {/* 培训 */}
            <h2 className="text-xl font-bold mb-3">{t('hr.trainingTitle')}</h2>
            {training.length === 0 ? (
                <p className="text-sm text-gray-500 mb-6">{t('hr.trainingEmpty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colTrainingName')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colCategory')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colCompletedDate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colExpiryDate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colProvider')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {training.map((tr) => (
                            <tr key={tr.id}>
                                <td className="border border-gray-300 px-3 py-2">
                                    <Link href={`/hr/training/${tr.id}/edit`} className="text-blue-600 hover:underline">
                                        {tr.training_name}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {tr.category ? t('hr.trainingCategory.' + tr.category) : '—'}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{tr.completed_date}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {tr.expiry_date ?? '—'}
                                    {tr.expiry_date && tr.expiry_date < today && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-red-100 text-red-800">
                                            {t('hr.severity.expired')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">{tr.provider ?? '—'}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* 绩效评估:零行(无权限或确实没有)时整节不渲染 */}
            {empReviews.length > 0 && (
                <>
                    <h2 className="text-xl font-bold mb-3">{t('reviews.sectionTitle')}</h2>
                    <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.type')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.cycle')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.period')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.status')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-left">{t('reviews.rating')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {empReviews.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <Link href={`/hr/reviews/${r.id}`} className="text-blue-600 hover:underline">
                                            {t(`reviews.type_${r.review_type}`)}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.cycle_id ? reviewCycleById.get(r.cycle_id) ?? '—' : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 whitespace-nowrap font-mono text-xs">
                                        {r.period_start} → {r.period_end}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <span className={'inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                                            {t(`reviews.status_${r.status}`)}
                                        </span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        {r.rating_code ? ratingNameByCode.get(r.rating_code) ?? r.rating_code : '—'}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </>
            )}

            {/* 薪资历史(受限) */}
            <h2 className="text-xl font-bold mb-1">{t('hr.payrollTitle')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('hr.payRestricted')}</p>
            {payroll.length === 0 ? (
                <p className="text-sm text-gray-500">{t('hr.payrollEmpty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colPeriod')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colGross')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployerCpf')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployeeCpf')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colDeductions')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colNet')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colStatus')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {payroll.map((p) => (
                            <tr key={p.id}>
                                <td className="border border-gray-300 px-3 py-2">
                                    {p.payroll_periods ? (
                                        <Link
                                            href={`/hr/payroll/${p.payroll_periods.id}`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {p.payroll_periods.period_month?.slice(0, 7)}
                                        </Link>
                                    ) : (
                                        '—'
                                    )}
                                    <span className="text-gray-400 ml-2">{p.payroll_periods?.currency}</span>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.gross_pay)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.employer_cpf)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.employee_cpf)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoney(p.other_deductions)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">{formatMoney(p.net_pay)}</td>
                                <td className="border border-gray-300 px-3 py-2">
                                    <span
                                        className={
                                            'px-2 py-0.5 rounded text-xs ' +
                                            (p.payroll_periods?.status === 'posted'
                                                ? 'bg-green-100 text-green-800'
                                                : 'bg-amber-100 text-amber-800')
                                        }
                                    >
                                        {t('hr.payrollStatus.' + (p.payroll_periods?.status ?? 'draft'))}
                                    </span>
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
