// app/me/page.tsx
// 员工自助。路由取 /me —— 短、无歧义、与模块名不冲突,而且每个人的地址都一样,
// 可以直接放进导航条(不像 /employees/<id> 那样因人而异)。
//
// 【这一页不看任何模块权限】。它靠的是 cut 4 的行级自助策略与 my_profile 视图:
// 账号关联了员工档案就有一行,没关联就零行 —— 后者显示"去找管理员"。
// 一个角色都没有的人在这里【什么都不缺】,那正是自助的意思。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoney } from '@/lib/format'
import MyLeavePanel from './MyLeavePanel'
import MyClaimsPanel from './MyClaimsPanel'
import MySelfAssessmentPanel, {
    type SelfAssessment,
    type SelfAssessmentGoal,
} from './MySelfAssessmentPanel'
import MyReviewsPanel from './MyReviewsPanel'
import { REVIEW_COLUMNS, type GoalRow, type ReviewRow } from '@/app/hr/reviews/reviewShared'
import type { RatingOption } from '@/app/hr/reviews/ConclusionForm'
import { mustRows } from '@/lib/db-helpers'

export default async function MePage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'
    const fmtDate = (v: string | null) =>
        v ? new Date(v).toLocaleDateString(dateLocale) : '—'

    const { data: profileRows } = await supabase.from('my_profile').select('*').limit(1)
    const p = profileRows?.[0]

    if (!p) {
        return (
            <div className="p-8 max-w-lg">
                <h1 className="text-2xl font-bold mb-3">{t('me.title')}</h1>
                <div className="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900">
                    <p className="font-medium">{t('me.notLinkedTitle')}</p>
                    <p className="text-sm mt-1">{t('me.notLinkedBody')}</p>
                </div>
            </div>
        )
    }

    // my_profile 的 WHERE 已经保证了这一行存在且有 id;视图没有 NOT NULL 约束,
    // 所以生成的类型把每一列都标成可空 —— 这里把它断言回来。
    const employeeId = p.employee_id as string

    // 自己的薪资、培训、任职历史 —— 全部由行级策略放行,不需要任何模块权限
    const [payRes, trainRes, histRes] = await Promise.all([
        supabase
            .from('payroll_lines_masked')
            .select('id, gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay, payroll_period_id')
            .eq('employee_id', employeeId),
        supabase
            .from('training_records')
            .select('id, training_name, category, completed_date, expiry_date, provider')
            .eq('employee_id', employeeId)
            .is('deleted_at', null)
            .order('completed_date', { ascending: false }),
        supabase
            .from('employment_history')
            .select('id, effective_date, change_type, job_title, employment_type, employment_status, notes')
            .eq('employee_id', employeeId)
            .order('effective_date', { ascending: false }),
    ])

    // 自助的假期与报销:全部靠 cut 4 的行级策略 + HR-2a 的函数,不需要任何模块权限
    const [balRes, myLeaveRes, typeRes, claimRes, claimBalRes] = await Promise.all([
        supabase.rpc('leave_balance', { p_employee_id: employeeId, p_leave_type_code: 'annual' }),
        supabase.from('leave_requests')
            .select('id, code, leave_type_code, start_date, end_date, days, status, created_at')
            .eq('employee_id', employeeId).is('deleted_at', null)
            .order('start_date', { ascending: false }).limit(50),
        supabase.from('leave_types')
            .select('code, name_en, name_zh, is_accrued, allows_half_day, requires_certificate_after_days, default_days_per_year')
            .eq('is_active', true).order('sort_order'),
        supabase.from('medical_claim_status').select('*')
            .eq('employee_id', employeeId).order('claim_date', { ascending: false }).limit(50),
        supabase.rpc('medical_claim_balance', {
            p_employee_id: employeeId, p_year: new Date().getFullYear(),
        }),
    ])

    // 绩效评估的自助两段(HR-3d):
    // 自评 —— 两个窄视图,只在 status='self_review' 时有行;
    // 定论 —— 行级策略只放行 approved/acknowledged,读到的都是定过的。
    const [selfAssessRes, selfGoalsRes, myReviewsRes, ratingRes] = await Promise.all([
        supabase.from('my_self_assessment').select('*'),
        supabase.from('my_self_assessment_goals').select('*'),
        supabase
            .from('performance_reviews_masked')
            .select(REVIEW_COLUMNS)
            .eq('employee_id', employeeId)
            .in('status', ['approved', 'acknowledged'])
            .order('period_end', { ascending: false }),
        supabase.from('review_rating_scale').select('code, name_en, name_zh, is_active').order('sort_order'),
    ])
    const myReviews = (mustRows(myReviewsRes)) as unknown as ReviewRow[]
    const { data: myReviewGoals } = myReviews.length
        ? await supabase
              .from('review_goals')
              .select(
                  'id, review_id, sequence, objective_text, target_value, unit, actual_value, employee_result_text, reviewer_assessment_text'
              )
              .in('review_id', myReviews.map((r) => r.id))
              .order('sequence')
        : { data: [] as GoalRow[] }

    const periodIds = Array.from(
        new Set((mustRows(payRes)).map((l) => l.payroll_period_id).filter((x): x is string => x !== null))
    )
    const { data: periods } = periodIds.length
        ? await supabase
              .from('payroll_periods')
              .select('id, code, period_month, payment_date')
              .in('id', periodIds)
        : { data: [] as { id: string; code: string; period_month: string; payment_date: string }[] }
    const periodById = new Map((periods ?? []).map((x) => [x.id, x]))

    const deptName = locale === 'zh' ? p.department_name_zh : p.department_name_en
    const card = 'rounded border border-gray-200 p-4'
    const dt = 'text-xs text-gray-500'
    const dd = 'text-sm font-medium'

    const today = new Date()
    const expiryState = (v: string | null) => {
        if (!v) return null
        const days = Math.round((new Date(v).getTime() - today.getTime()) / 86400000)
        if (days < 0) return { key: 'me.expired', cls: 'bg-red-100 text-red-800' }
        if (days <= 30) return { key: 'me.expiringSoon', cls: 'bg-amber-100 text-amber-800' }
        return null
    }

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-1">{t('me.title')}</h1>
            <p className="text-sm text-gray-500 mb-6">{t('me.subtitle')}</p>

            {/* ── profile ── */}
            <section className={card + ' mb-6'}>
                <div className="flex items-baseline gap-3 mb-4">
                    <h2 className="text-xl font-bold">{p.preferred_name || p.legal_name}</h2>
                    <span className="font-mono text-sm text-gray-500">{p.code}</span>
                </div>
                <div className="grid gap-4 sm:grid-cols-3">
                    <div>
                        <div className={dt}>{t('me.department')}</div>
                        <div className={dd}>{deptName ?? '—'}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.jobTitle')}</div>
                        <div className={dd}>{p.job_title ?? '—'}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.manager')}</div>
                        <div className={dd}>
                            {p.manager_name ? `${p.manager_code} — ${p.manager_name}` : '—'}
                        </div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.employmentType')}</div>
                        <div className={dd}>{p.employment_type ?? '—'}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.hireDate')}</div>
                        <div className={dd}>{fmtDate(p.hire_date)}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.annualLeaveAvailable')}</div>
                        <div className={dd + ' font-mono'}>{p.annual_leave_available_days ?? 0} {t('me.days')}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.annualLeaveAccrued')}</div>
                        <div className={dd + ' font-mono'}>{p.annual_leave_accrued_days ?? 0} {t('me.days')}</div>
                    </div>
                    <div>
                        <div className={dt}>{t('me.annualLeaveRate')}</div>
                        <div className={dd + ' font-mono'}>{p.annual_leave_rate_days ?? 0} {t('me.daysPerYear')}</div>
                        <p className="text-xs text-gray-500 mt-1 max-w-md">{t('me.annualLeaveHint')}</p>
                    </div>
                    {p.work_pass_type && (
                        <>
                            <div>
                                <div className={dt}>{t('me.workPassType')}</div>
                                <div className={dd}>{p.work_pass_type}</div>
                            </div>
                            <div>
                                <div className={dt}>{t('me.workPassExpiry')}</div>
                                <div className={dd}>
                                    {fmtDate(p.work_pass_expiry_date)}
                                    {(() => {
                                        const s = expiryState(p.work_pass_expiry_date)
                                        return s ? (
                                            <span className={`ml-2 rounded px-1.5 py-0.5 text-xs ${s.cls}`}>
                                                {t(s.key)}
                                            </span>
                                        ) : null
                                    })()}
                                </div>
                            </div>
                        </>
                    )}
                </div>
            </section>

            {/* ── payslips: own figures in full ── */}
            <section className="mb-6">
                <h2 className="text-lg font-bold mb-2">{t('me.payslips')}</h2>
                {(mustRows(payRes)).length === 0 ? (
                    <p className="text-sm text-gray-500">{t('me.noPayslips')}</p>
                ) : (
                    <table className="w-full border-collapse text-sm">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-3 py-2">{t('me.period')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('me.gross')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('me.employerCpf')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('me.employeeCpf')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('me.deductions')}</th>
                                <th className="border border-gray-300 px-3 py-2 text-right">{t('me.net')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {(mustRows(payRes)).map((l) => {
                                const per = l.payroll_period_id ? periodById.get(l.payroll_period_id) : undefined
                                return (
                                    <tr key={l.id}>
                                        <td className="border border-gray-300 px-3 py-2">
                                            {per ? per.code : '—'}
                                            {per?.period_month && (
                                                <span className="ml-2 text-xs text-gray-500">
                                                    {fmtDate(per.period_month)}
                                                </span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatMoney(l.gross_pay)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatMoney(l.employer_cpf)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatMoney(l.employee_cpf)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatMoney(l.other_deductions)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">
                                            {formatMoney(l.net_pay)}
                                        </td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                )}
            </section>

            {/* ── training ── */}
            <section className="mb-6">
                <h2 className="text-lg font-bold mb-2">{t('me.training')}</h2>
                {(mustRows(trainRes)).length === 0 ? (
                    <p className="text-sm text-gray-500">{t('me.noTraining')}</p>
                ) : (
                    <table className="w-full border-collapse text-sm">
                        <thead>
                            <tr className="bg-gray-50 text-left">
                                <th className="border border-gray-300 px-3 py-2">{t('me.trainingName')}</th>
                                <th className="border border-gray-300 px-3 py-2">{t('me.completed')}</th>
                                <th className="border border-gray-300 px-3 py-2">{t('me.expires')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {(mustRows(trainRes)).map((r) => {
                                const s = expiryState(r.expiry_date)
                                return (
                                    <tr key={r.id}>
                                        <td className="border border-gray-300 px-3 py-2">
                                            {r.training_name}
                                            {r.provider && (
                                                <span className="ml-2 text-xs text-gray-500">{r.provider}</span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2">
                                            {fmtDate(r.completed_date)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2">
                                            {fmtDate(r.expiry_date)}
                                            {s && (
                                                <span className={`ml-2 rounded px-1.5 py-0.5 text-xs ${s.cls}`}>
                                                    {t(s.key)}
                                                </span>
                                            )}
                                        </td>
                                    </tr>
                                )
                            })}
                        </tbody>
                    </table>
                )}
            </section>

            {/* ── employment history ── */}
            <section className="mb-6">
                <h2 className="text-lg font-bold mb-2">{t('me.history')}</h2>
                {(mustRows(histRes)).length === 0 ? (
                    <p className="text-sm text-gray-500">{t('me.noHistory')}</p>
                ) : (
                    <ol className="border-l border-gray-200 pl-4 space-y-3">
                        {(mustRows(histRes)).map((h) => (
                            <li key={h.id} className="relative">
                                <span className="absolute -left-[21px] top-1.5 h-2 w-2 rounded-full bg-gray-400" />
                                <div className="text-sm font-medium">
                                    {t(`hr.changeType.${h.change_type}`)}
                                    <span className="ml-2 text-xs text-gray-500">
                                        {fmtDate(h.effective_date)}
                                    </span>
                                </div>
                                <div className="text-sm text-gray-600">
                                    {[h.job_title, h.employment_type, h.employment_status]
                                        .filter(Boolean)
                                        .join(' · ') || '—'}
                                </div>
                                {h.notes && <div className="text-xs text-gray-500">{h.notes}</div>}
                            </li>
                        ))}
                    </ol>
                )}
            </section>

            {(mustRows(selfAssessRes)).length > 0 && (
                <MySelfAssessmentPanel
                    assessments={(mustRows(selfAssessRes)) as unknown as SelfAssessment[]}
                    goals={(mustRows(selfGoalsRes)) as unknown as SelfAssessmentGoal[]}
                />
            )}

            {myReviews.length > 0 && (
                <MyReviewsPanel
                    reviews={myReviews}
                    goals={(myReviewGoals ?? []) as unknown as GoalRow[]}
                    ratings={(mustRows(ratingRes)) as unknown as RatingOption[]}
                />
            )}

            <MyLeavePanel
                employeeId={employeeId}
                balance={balRes.data as never}
                requests={(mustRows(myLeaveRes)) as never}
                types={(mustRows(typeRes)) as never}
            />

            <MyClaimsPanel
                employeeId={employeeId}
                claims={(mustRows(claimRes)) as never}
                balance={claimBalRes.data as never}
            />

            <p className="text-sm text-gray-400 italic">{t('me.comingSoon')}</p>
        </div>
    )
}
