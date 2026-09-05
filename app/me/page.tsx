// app/me/page.tsx
// 员工自助。路由取 /me —— 短、无歧义、与模块名不冲突,而且每个人的地址都一样,
// 可以直接放进导航条(不像 /employees/<id> 那样因人而异)。
//
// 【这一页不看任何模块权限】。它靠的是 cut 4 的行级自助策略与 my_profile 视图:
// 账号关联了员工档案就有一行,没关联就零行 —— 后者显示"去找管理员"。
// 一个角色都没有的人在这里【什么都不缺】,那正是自助的意思。
import { cookies } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import MyLeavePanel from './MyLeavePanel'
import MyClaimsPanel from './MyClaimsPanel'
import MyExpenseClaimsPanel from './MyExpenseClaimsPanel'
import MyAttendancePanel from './MyAttendancePanel'
import MySelfAssessmentPanel, {
    type SelfAssessment,
    type SelfAssessmentGoal,
} from './MySelfAssessmentPanel'
import MyReviewsPanel from './MyReviewsPanel'
import { REVIEW_COLUMNS, type GoalRow, type ReviewRow } from '@/app/hr/reviews/reviewShared'
import type { RatingOption } from '@/app/hr/reviews/ConclusionForm'
import { mustRows } from '@/lib/db-helpers'
import AvatarPanel from './AvatarPanel'
import { initialsOf } from '@/lib/initials'
import { AVATAR_BUCKET, AVATAR_VERSION_COOKIE, avatarObjectName } from '@/lib/avatar'

type MyKpiRow = {
    id: string; cycle_name: string; cycle_status: string; gate: string | null
    position_code: string; position_title: string
    kpi_ref: string; title: string; weight_pct: number; target_text: string
    evidence_source: string | null
    is_provisional: boolean; provisional_note: string | null
    org_codes: string[]; source_template_version: number
    score_visible: boolean; score: number | null; score_kind: string | null
    computed_basis: string | null; evidence_note: string | null
    override_cap: number | null; override_reason: string | null
}

export default async function MePage() {
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    // 自助页上一个币种都没写:工资条五栏、评估里的调薪,全靠数字自己带。
    // 工资条带的是【那一期自己的币种】(payroll_periods.currency,下面一并取回),
    // 调薪没有随行币种 —— 那是本位币的月薪。
    const baseCurrency = await getBaseCurrency()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'
    const fmtDate = (v: string | null) =>
        v ? new Date(v).toLocaleDateString(dateLocale) : '—'

    const { data: profileRows } = await supabase.from('my_profile').select('*').limit(1)

    // KPI-1:自己这个周期被考核的那五条。**条目与目标始终可见**(期初就该知道),
    // **而分数只在周期关掉之后才可见** —— 两者的区别写在 my_kpi_entries 的视图注里。
    const myKpi = mustRows(
        await supabase.from('my_kpi_entries').select('*').order('kpi_ref'),
        'my_kpi_entries') as unknown as MyKpiRow[]
    const p = profileRows?.[0]

    // ════════════════════════════════════════════════════════════════════════
    // UI-1d:换头像那一段。**它算在早返回【之前】,而且两条分支都画。**
    // ════════════════════════════════════════════════════════════════════════
    //
    // ★【为什么必须在早返回之前】★ 下面那句 `if (!p) return …` 是给
    //   【账号还没连上员工档案】的人准备的一句"去找管理员"。而头像挂在
    //   **auth 账号**上,不挂在员工档案上(UI-1d Step 2 的裁定,理由是
    //   AvatarMenu 早就刻意接住了"没有员工档案"这一情形 —— 把头像挂到
    //   employees 上等于宣布这些账号【永远】不能有头像)。
    //   于是这一段跨在早返回两侧:没建档的人照样换得了自己的头像,
    //   而他的【名字】那一行仍然不画 —— 那是 UI-1a 的判据,本刀没碰。
    //
    // 【认证的三态在这里也活着】(scripts/check-auth-error-swallowing.mjs)
    //   问不出来 ≠ 没登录。问不出来时【不画】这一段,并说一句为什么 ——
    //   用的是顶栏那两句现成的话,免得同一件事在系统里有两种说法。
    let meUser = null
    let meAuthError: unknown = null
    try {
        const res = await supabase.auth.getUser()
        meUser = res.data.user
        meAuthError = res.error
    } catch (e) {
        meAuthError = e
    }
    const avatarIndeterminate =
        !meUser && (meAuthError as { name?: string } | null)?.name === 'AuthRetryableFetchError'
    // 与顶栏【同一个地址】:同一个 lib/avatar.ts 拼的,同一个 cookie 挂的尾巴。
    const meAvatarVersion = (await cookies()).get(AVATAR_VERSION_COOKIE)?.value ?? null
    const meAvatarUrl = meUser
        ? (() => {
              const base = supabase.storage
                  .from(AVATAR_BUCKET)
                  .getPublicUrl(avatarObjectName(meUser.id)).data.publicUrl
              return meAvatarVersion ? `${base}?v=${encodeURIComponent(meAvatarVersion)}` : base
          })()
        : null
    const avatarSection = meUser ? (
        <AvatarPanel
            avatarUrl={meAvatarUrl}
            initials={initialsOf(
                (p?.preferred_name || p?.legal_name) ?? null,
                meUser.email ?? ''
            )}
        />
    ) : avatarIndeterminate ? (
        <div className="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900 mb-6">
            <p className="font-medium">{t('common.navUnavailable')}</p>
            <p className="text-sm mt-1">{t('common.navUnavailableHint')}</p>
        </div>
    ) : null

    if (!p) {
        return (
            <div className="p-8 max-w-lg">
                <h1 className="text-2xl font-bold mb-3">{t('me.title')}</h1>
                {/* ★ 没有员工档案的人【也换得了头像】—— 见上面那段抬头。 */}
                {avatarSection}
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
    const [balRes, myLeaveRes, typeRes, claimRes, claimBalRes, expenseClaimRes] = await Promise.all([
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
        // CLAIM-1：一般费用报销。与医疗那一块【并排】而不是合并 ——
        // 医疗唯一属于医疗的东西是年度限额，而这一种要科目、币种、税码。
        supabase.from('expense_claim_status').select('*')
            .eq('employee_id', employeeId).order('spend_date', { ascending: false }).limit(50),
    ])

    // ATTEND-1:自己那几行考勤。行级策略放行 employee_id = current_user_employee(),
    // 所以这里【不加】模块权限 —— 与这一页其余部分同一条路。期间的 code/月份要
    // 另取:attendance_lines 上没有,而 attendance_periods 的读策略也放行本人。
    const myLinesRes = await supabase
        .from('attendance_lines')
        .select('id, period_id, ot_normal_hours, ot_rest_day_hours, ot_public_holiday_hours, note, recorded_at, unpaid_days')
        .eq('employee_id', employeeId)
    const myLines = mustRows(myLinesRes)
    const myPeriodIds = [...new Set(myLines.map((l) => l.period_id))]
    const myPeriods = myPeriodIds.length
        ? mustRows(await supabase.from('attendance_periods')
            .select('id, code, period_month, status').in('id', myPeriodIds))
        : []
    // 【不叫 periodById】这一页下面已经有一个同名的 —— 那是【薪资】期间。
    // tsc 抓到了这次重名;两个都留着各自的全名,读的人就不必猜是哪一种期间。
    const attPeriodById = new Map(myPeriods.map((x) => [x.id, x]))
    const myAttendance = myLines
        .map((l) => ({
            code: attPeriodById.get(l.period_id)?.code ?? '—',
            periodMonth: attPeriodById.get(l.period_id)?.period_month ?? '',
            status: attPeriodById.get(l.period_id)?.status ?? '',
            normal: Number(l.ot_normal_hours ?? 0),
            restDay: Number(l.ot_rest_day_hours ?? 0),
            holiday: Number(l.ot_public_holiday_hours ?? 0),
            note: l.note,
            recorded: l.recorded_at !== null,
            unpaidDays: l.unpaid_days === null ? null : Number(l.unpaid_days),
        }))
        .sort((a, b) => b.periodMonth.localeCompare(a.periodMonth))

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
              .select('id, code, period_month, payment_date, currency')
              .in('id', periodIds)
        : { data: [] as { id: string; code: string; period_month: string; payment_date: string; currency: string }[] }
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

            {avatarSection}

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
                                            {formatAmount(l.gross_pay, per?.currency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatAmount(l.employer_cpf, per?.currency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatAmount(l.employee_cpf, per?.currency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                            {formatAmount(l.other_deductions, per?.currency)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">
                                            {formatAmount(l.net_pay, per?.currency)}
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
                    baseCurrency={baseCurrency}
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

            <MyExpenseClaimsPanel
                employeeId={employeeId}
                rows={(mustRows(expenseClaimRes)) as never}
                baseCurrency={baseCurrency}
            />

            {/* ── KPI-1:我这个周期被考核的那五条 ────────────────────────────
                ★【整段服务端渲染,没有客户端开关】★ 抬头与说明都在初次 HTML 里,
                  否则 fetch 冒烟看不见它(昨天记下的第三条盲区)。
                【为什么没有条目时也要说话】一个人没有 KPI,可能是"还没挂职位"、
                  也可能是"挂了职位但这个周期还没生成" —— 两句话的下一步不同,
                  而一片空白两句都说不出来。 */}
            <section className="mb-8">
                <h2 className="text-lg font-semibold mb-1">{t('kpi.myTitle')}</h2>
                <p className="text-xs text-gray-600 mb-3 max-w-3xl">{t('kpi.myWhat')}</p>
                {myKpi.length === 0 ? (
                    <p className="text-sm text-gray-600">
                        {p?.position_code ? t('kpi.myNoneThisCycle') : t('kpi.myNoPosition')}
                    </p>
                ) : (
                    <div className="space-y-3">
                        {myKpi.map((k) => (
                            <div key={k.id} className="border border-gray-300 rounded p-3">
                                <div className="flex flex-wrap items-baseline gap-2">
                                    <span className="font-mono text-xs text-gray-500">{k.kpi_ref}</span>
                                    <span className="font-medium">{k.title}</span>
                                    <span className="text-sm text-gray-700">— {k.weight_pct}%</span>
                                    <span className="text-xs text-gray-500">{k.org_codes.join(' / ')}</span>
                                    {k.is_provisional && (
                                        <span className="text-xs bg-amber-100 text-amber-900 border border-amber-300 px-2 py-0.5 rounded">
                                            {t('kpi.provisionalTag')}
                                        </span>
                                    )}
                                </div>
                                <p className="text-sm text-gray-800 mt-1">{k.target_text}</p>
                                {/* 【证据来源:原表三十格全空 —— 具名的缺席,不是留白】 */}
                                <p className="text-xs text-gray-500 mt-1">
                                    {k.evidence_source ?? t('kpi.noEvidenceSource')}
                                </p>
                                {k.is_provisional && k.provisional_note && (
                                    <p className="mt-2 text-xs text-amber-900 bg-amber-50 border-l-4 border-amber-400 p-2">
                                        {k.provisional_note}
                                    </p>
                                )}
                                {/* ★ 分数:没到时候就说【为什么没有】,不是留白 ★ */}
                                <div className="mt-2 text-sm">
                                    {!k.score_visible ? (
                                        <span className="text-gray-500 text-xs">{t('kpi.scoreHiddenUntilClosed')}</span>
                                    ) : k.score === null ? (
                                        <span className="text-gray-500 text-xs">{t('kpi.scoreNotGiven')}</span>
                                    ) : (
                                        <>
                                            {/* ★★ 4.3:算出来的分与人判的分【长得不一样】★★ */}
                                            {k.score_kind === 'computed' ? (
                                                <span className="inline-flex items-center gap-1 font-mono bg-slate-800 text-white px-2 py-0.5 rounded">
                                                    {k.score}/5
                                                    <span className="text-[10px] font-sans">{t('kpi.computedTag')}</span>
                                                </span>
                                            ) : (
                                                <span className="inline-flex items-center gap-1 italic border border-dashed border-gray-500 px-2 py-0.5 rounded">
                                                    {k.score}/5
                                                    <span className="text-[10px] not-italic">{t('kpi.judgedTag')}</span>
                                                </span>
                                            )}
                                            {k.score_kind === 'computed' && k.computed_basis && (
                                                <span className="ml-2 text-xs text-gray-600">{k.computed_basis}</span>
                                            )}
                                            {k.override_cap !== null && (
                                                <span className="ml-2 text-xs text-red-800">
                                                    {t('kpi.cappedAt', { cap: String(k.override_cap) })} — {k.override_reason}
                                                </span>
                                            )}
                                        </>
                                    )}
                                </div>
                            </div>
                        ))}
                    </div>
                )}
            </section>

            <MyAttendancePanel rows={myAttendance} />

            <p className="text-sm text-gray-400 italic">{t('me.comingSoon')}</p>
        </div>
    )
}
