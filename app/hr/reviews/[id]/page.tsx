// app/hr/reviews/[id]/page.tsx
// 评估文档(HR 视角)。字段契约(HR-3c 迁移头)在这里的读法:
// 本页读遮蔽伴生视图,行进不来的人直接 notFound;薪酬段只对 data.view_pay 渲染。
// 写入的每一道闸都在 DB;页面只负责【不画注定失败的按钮】。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import GoalsEditor from '../GoalsEditor'
import ConclusionForm, { type RatingOption } from '../ConclusionForm'
import ReviewActions from '../ReviewActions'
import HrDecisionForm from '../HrDecisionForm'
import SetReviewerControl, { type EmployeeOption } from '../SetReviewerControl'
import { REVIEW_COLUMNS, type GoalRow, type ReviewRow, daysInState, statusPillClass } from '../reviewShared'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function ReviewDetailPage({ params }: { params: Promise<{ id: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    // 调薪是【本位币】的月薪,而这一页上下没有任何一处写着币种 —— 所以数字自己带上。
    const baseCurrency = await getBaseCurrency()

    const { data: reviewRow } = await supabase
        .from('performance_reviews_masked')
        .select(REVIEW_COLUMNS)
        .eq('id', id)
        .maybeSingle()
    if (!reviewRow) notFound()
    const r = reviewRow as unknown as ReviewRow

    const [goalsRes, ratingRes, empRes, cycleRes, meRes, userRes, canHrEdit, canPay] =
        await Promise.all([
            supabase
                .from('review_goals')
                .select(
                    'id, review_id, sequence, objective_text, target_value, unit, actual_value, employee_result_text, reviewer_assessment_text'
                )
                .eq('review_id', id)
                .order('sequence'),
            supabase
                .from('review_rating_scale')
                .select('code, name_en, name_zh, is_active')
                .order('sort_order'),
            supabase
                .from('employees')
                .select('id, code, legal_name, employment_status')
                .is('deleted_at', null)
                .order('code'),
            r.cycle_id
                ? supabase.from('review_cycles').select('name').eq('id', r.cycle_id).maybeSingle()
                : Promise.resolve({ data: null, error: null }),
            supabase.rpc('current_user_employee'),
            supabase.auth.getUser(),
            can('module.hr.edit'),
            can('data.view_pay'),
        ])

    const goals = (goalsRes.data as unknown as GoalRow[] | null) ?? []
    const ratings = (ratingRes.data as unknown as RatingOption[] | null) ?? []
    const employees = (empRes.data as unknown as (EmployeeOption & { employment_status: string })[] | null) ?? []
    const cycleName = (cycleRes.data as { name: string } | null)?.name ?? null
    // 读不到就必须炸:它喂给 isReviewer → canWrite,失败会静默改写整页的写权限
    const myEmployeeId = mustOne(meRes, 'current_user_employee') as string | null
    const uid = userRes.data.user?.id ?? null

    const empById = new Map(employees.map((e) => [e.id, e]))
    const subject = empById.get(r.employee_id)
    const reviewer = r.reviewer_employee_id ? empById.get(r.reviewer_employee_id) : null

    const isReviewer = myEmployeeId !== null && r.reviewer_employee_id === myEmployeeId
    const canWrite = canHrEdit || isReviewer
    const isSubmitter = r.submitted_by !== null && r.submitted_by === uid
    const preApproval = ['draft', 'self_review', 'submitted'].includes(r.status)

    // ════════════════════════════════════════════════════════════════════════
    // ★★【ALERT-2d(2026-09-09)· 权限与记录状态从此是两样东西】★★
    // ════════════════════════════════════════════════════════════════════════
    //   这一页此前把它们乘在一起递下去:
    //     canEditGoals={canWrite && r.status === 'draft'}
    //     canAssess   ={canWrite && (r.status === 'draft' || r.status === 'self_review')}
    //     canSetActual={canWrite && (r.status === 'draft' || r.status === 'submitted')}
    //     editable    ={canWrite && (r.status === 'draft' || r.status === 'self_review')}
    //   `DBLOCK-CONFLATED-BOOLEANS` 就是拿这四行当样板立的案。四个布尔为假各有
    //   两个原因,而屏幕上【一个字都不说】—— 它不是在说错原因,它是什么都不说。
    //
    //   现在:递下去的三个 prop 只装【记录状态】,权限那一半由
    //   `<PermissionGate>` 在外面挡,并带上【另一条路】。
    //
    //   ★【为什么是 alsoAllowedIf,而不是只报 module.hr.edit】★
    //     `canWrite = canHrEdit || isReviewer` —— 一边是管理员勾得出来的码,
    //     一边是"这份考核点名的评估人是不是你",一次**关系授权**。
    //     对一个被挡住的读者,更可能为真的是后者,而**没有任何管理员给得了它**。
    //     只说那个码,就是把人支去要一样要来了也未必管用的东西。
    //
    //   ★【为什么先问状态、再问权限】★ 一份已经批准/作废的考核,对【任何人】
    //     都改不动 —— 那时再挂一句"你还需要某项权限"是正确而无用的。
    //     所以状态不许时只说状态;状态许了,缺的才真的只剩权限。
    const orReviewer = {
        label: t('reviews.gate.orReviewer'),
        why: t('reviews.gate.orReviewerWhy'),
    }
    const statusName = t(`reviews.status_${r.status}`)
    // 记录状态那一半 —— 与 DB 里那几支函数各自的状态判据一一对应。
    const stateGoals = r.status === 'draft'
    const stateAssess = r.status === 'draft' || r.status === 'self_review'
    const stateActual = r.status === 'draft' || r.status === 'submitted'
    const stateConclusion = r.status === 'draft' || r.status === 'self_review'
    const ratingName = (code: string | null) => {
        if (!code) return '—'
        const x = ratings.find((s) => s.code === code)
        return x ? (locale === 'zh' ? x.name_zh : x.name_en) : code
    }

    return (
        <div className="p-8 max-w-6xl">
            <Link href="/hr/reviews" className="text-sm hover:underline app-link app-link-inline">
                {t('common.back')}
            </Link>

            <div className="flex justify-between items-start mt-2 mb-4">
                <h1 className="">
                    {subject ? subject.legal_name : t('reviews.detailTitle')}
                    <span className="ml-2 font-mono text-sm text-[color:var(--brand-muted-text)]">{subject?.code}</span>
                    <span className={'ml-3 align-middle inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                        {t(`reviews.status_${r.status}`)}
                    </span>
                </h1>
            </div>

            {r.status === 'void' && (
                <div className="mb-4 rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {t('reviews.voidBanner', { 0: r.void_reason ?? '' })}
                </div>
            )}

            {/* 抬头 */}
            <div className="bg-gray-50 rounded p-4 mb-6 grid grid-cols-2 md:grid-cols-3 gap-x-8 gap-y-2 text-sm">
                <div>
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.type')}:</span>
                    {t(`reviews.type_${r.review_type}`)}
                </div>
                <div>
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.cycle')}:</span>
                    {cycleName ?? '—'}
                </div>
                <div>
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.period')}:</span>
                    <span className="font-mono">{r.period_start} → {r.period_end}</span>
                </div>
                <div className="col-span-2">
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.reviewer')}:</span>
                    {reviewer ? (
                        <>
                            <span className="font-mono">{reviewer.code}</span> {reviewer.legal_name}{' '}
                        </>
                    ) : (
                        <span className="text-red-700 mr-2">{t('reviews.noReviewer')}</span>
                    )}
                    {canHrEdit && preApproval && (
                        <SetReviewerControl
                            reviewId={r.id}
                            employees={employees.filter((e) => e.employment_status !== 'separated')}
                            currentReviewerId={r.reviewer_employee_id}
                            subjectEmployeeId={r.employee_id}
                        />
                    )}
                </div>
                <div>
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.inState')}:</span>
                    {t('hr.daysRemaining', { n: daysInState(r) })}
                </div>
                {!canWrite || !preApproval ? (
                    <div>
                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.rating')}:</span>
                        {ratingName(r.rating_code)}
                    </div>
                ) : null}
                {canPay && (r.new_monthly_salary !== null || r.salary_effective_date !== null) && !canHrEdit && (
                    <div>
                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.newSalary')}:</span>
                        <span className="font-mono">{formatAmount(r.new_monthly_salary, baseCurrency)}</span>
                        <span className="ml-2 text-[color:var(--brand-muted-text)]">{r.salary_effective_date}</span>
                    </div>
                )}
            </div>

            {/* 自评 */}
            {(r.self_assessment_text || r.self_assessment_submitted_at) && (
                <div className="mb-6">
                    <h2 className="mb-1">{t('reviews.selfAssessmentTitle')}</h2>
                    {r.self_assessment_submitted_at && (
                        <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                            {t('reviews.selfAssessmentSubmittedAt', { 0: r.self_assessment_submitted_at.slice(0, 10) })}
                        </p>
                    )}
                    <p className="text-sm whitespace-pre-wrap">{r.self_assessment_text ?? '—'}</p>
                </div>
            )}

            {/* 目标 */}
            <h2 className="mb-3">{t('reviews.goalsTitle')}</h2>
            {(() => {
                const editor = (
                    <GoalsEditor
                        reviewId={r.id}
                        goals={goals}
                        canEditGoals={stateGoals}
                        canAssess={stateAssess}
                        canSetActual={stateActual}
                        stateNote={t('reviews.stateGoalsLocked', { 0: statusName })}
                    />
                )
                // 状态已经把所有人挡在外面时,不再叠一句权限的话(见上面的理由)。
                return stateGoals || stateAssess || stateActual ? (
                    <PermissionGate
                        code="module.hr.edit"
                        allowed={canWrite}
                        alsoAllowedIf={orReviewer}
                        className="flex w-full items-stretch"
                    >
                        {editor}
                    </PermissionGate>
                ) : (
                    editor
                )
            })()}

            {/* 结论 */}
            <h2 className="mb-3">{t('reviews.conclusionTitle')}</h2>
            {(() => {
                const form = (
                    <ConclusionForm
                        reviewId={r.id}
                        ratings={ratings}
                        ratingCode={r.rating_code}
                        summaryText={r.summary_text}
                        editable={stateConclusion}
                        stateNote={
                            stateConclusion ? null : t('reviews.stateConclusionLocked', { 0: statusName })
                        }
                    />
                )
                return stateConclusion ? (
                    <PermissionGate
                        code="module.hr.edit"
                        allowed={canWrite}
                        alsoAllowedIf={orReviewer}
                        className="flex w-full items-stretch"
                    >
                        {form}
                    </PermissionGate>
                ) : (
                    form
                )
            })()}

            {/* HR 的决定:试用期结论 + 调薪(薪酬段只对 data.view_pay 渲染) */}
            {canHrEdit ? (
                <HrDecisionForm
                    reviewId={r.id}
                    reviewType={r.review_type}
                    probationOutcome={r.probation_outcome}
                    newMonthlySalary={r.new_monthly_salary}
                    salaryEffectiveDate={r.salary_effective_date}
                    canPay={canPay}
                    editable={preApproval}
                />
            ) : (
                r.review_type === 'probation' && (
                    <div className="mb-6 text-sm">
                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.probationOutcome')}:</span>
                        {r.probation_outcome ? t(`reviews.outcome_${r.probation_outcome}`) : '—'}
                        {r.probation_outcome === 'not_confirm' && (
                            <div className="mt-2 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-amber-900 max-w-2xl">
                                {t('reviews.notConfirmManual')}
                            </div>
                        )}
                    </div>
                )
            )}

            <ReviewActions
                reviewId={r.id}
                status={r.status}
                reviewType={r.review_type}
                probationOutcome={r.probation_outcome}
                selfAssessmentLocked={r.self_assessment_submitted_at !== null}
                canWrite={canWrite}
                canHrEdit={canHrEdit}
                isSubmitter={isSubmitter}
            />
        </div>
    )
}
