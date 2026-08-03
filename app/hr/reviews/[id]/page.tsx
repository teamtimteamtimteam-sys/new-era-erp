// app/hr/reviews/[id]/page.tsx
// 评估文档(HR 视角)。字段契约(HR-3c 迁移头)在这里的读法:
// 本页读遮蔽伴生视图,行进不来的人直接 notFound;薪酬段只对 data.view_pay 渲染。
// 写入的每一道闸都在 DB;页面只负责【不画注定失败的按钮】。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { formatUsd } from '@/lib/format'
import Subnav from '../../Subnav'
import GoalsEditor from '../GoalsEditor'
import ConclusionForm, { type RatingOption } from '../ConclusionForm'
import ReviewActions from '../ReviewActions'
import HrDecisionForm from '../HrDecisionForm'
import SetReviewerControl, { type EmployeeOption } from '../SetReviewerControl'
import { REVIEW_COLUMNS, type GoalRow, type ReviewRow, daysInState, statusPillClass } from '../reviewShared'

export default async function ReviewDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

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
                : Promise.resolve({ data: null }),
            supabase.rpc('current_user_employee'),
            supabase.auth.getUser(),
            can('module.hr.edit'),
            can('data.view_pay'),
        ])

    const goals = (goalsRes.data as unknown as GoalRow[] | null) ?? []
    const ratings = (ratingRes.data as unknown as RatingOption[] | null) ?? []
    const employees = (empRes.data as unknown as (EmployeeOption & { employment_status: string })[] | null) ?? []
    const cycleName = (cycleRes.data as { name: string } | null)?.name ?? null
    const myEmployeeId = (meRes.data as string | null) ?? null
    const uid = userRes.data.user?.id ?? null

    const empById = new Map(employees.map((e) => [e.id, e]))
    const subject = empById.get(r.employee_id)
    const reviewer = r.reviewer_employee_id ? empById.get(r.reviewer_employee_id) : null

    const isReviewer = myEmployeeId !== null && r.reviewer_employee_id === myEmployeeId
    const canWrite = canHrEdit || isReviewer
    const isSubmitter = r.submitted_by !== null && r.submitted_by === uid
    const preApproval = ['draft', 'self_review', 'submitted'].includes(r.status)
    const ratingName = (code: string | null) => {
        if (!code) return '—'
        const x = ratings.find((s) => s.code === code)
        return x ? (locale === 'zh' ? x.name_zh : x.name_en) : code
    }

    return (
        <div className="p-8 max-w-6xl">
            <Link href="/hr/reviews" className="text-sm text-blue-600 hover:underline">
                {t('common.back')}
            </Link>

            <div className="flex justify-between items-start mt-2 mb-4">
                <h1 className="text-2xl font-bold">
                    {subject ? subject.legal_name : t('reviews.detailTitle')}
                    <span className="ml-2 font-mono text-base text-gray-500">{subject?.code}</span>
                    <span className={'ml-3 align-middle inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                        {t(`reviews.status_${r.status}`)}
                    </span>
                </h1>
            </div>

            <Subnav />

            {r.status === 'void' && (
                <div className="mb-4 rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800">
                    {t('reviews.voidBanner', { 0: r.void_reason ?? '' })}
                </div>
            )}

            {/* 抬头 */}
            <div className="bg-gray-50 rounded p-4 mb-6 grid grid-cols-2 md:grid-cols-3 gap-x-8 gap-y-2 text-sm">
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.type')}:</span>
                    {t(`reviews.type_${r.review_type}`)}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.cycle')}:</span>
                    {cycleName ?? '—'}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.period')}:</span>
                    <span className="font-mono">{r.period_start} → {r.period_end}</span>
                </div>
                <div className="col-span-2">
                    <span className="text-gray-600 mr-1">{t('reviews.reviewer')}:</span>
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
                    <span className="text-gray-600 mr-1">{t('reviews.inState')}:</span>
                    {t('hr.daysRemaining', { n: daysInState(r) })}
                </div>
                {!canWrite || !preApproval ? (
                    <div>
                        <span className="text-gray-600 mr-1">{t('reviews.rating')}:</span>
                        {ratingName(r.rating_code)}
                    </div>
                ) : null}
                {canPay && (r.new_monthly_salary !== null || r.salary_effective_date !== null) && !canHrEdit && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('reviews.newSalary')}:</span>
                        <span className="font-mono">{formatUsd(r.new_monthly_salary)}</span>
                        <span className="ml-2 text-gray-500">{r.salary_effective_date}</span>
                    </div>
                )}
            </div>

            {/* 自评 */}
            {(r.self_assessment_text || r.self_assessment_submitted_at) && (
                <div className="mb-6">
                    <h2 className="text-xl font-bold mb-1">{t('reviews.selfAssessmentTitle')}</h2>
                    {r.self_assessment_submitted_at && (
                        <p className="text-xs text-gray-500 mb-2">
                            {t('reviews.selfAssessmentSubmittedAt', { 0: r.self_assessment_submitted_at.slice(0, 10) })}
                        </p>
                    )}
                    <p className="text-sm whitespace-pre-wrap">{r.self_assessment_text ?? '—'}</p>
                </div>
            )}

            {/* 目标 */}
            <h2 className="text-xl font-bold mb-3">{t('reviews.goalsTitle')}</h2>
            <GoalsEditor
                reviewId={r.id}
                goals={goals}
                canEditGoals={canWrite && r.status === 'draft'}
                canAssess={canWrite && (r.status === 'draft' || r.status === 'self_review')}
                canSetActual={canWrite && (r.status === 'draft' || r.status === 'submitted')}
            />

            {/* 结论 */}
            <h2 className="text-xl font-bold mb-3">{t('reviews.conclusionTitle')}</h2>
            <ConclusionForm
                reviewId={r.id}
                ratings={ratings}
                ratingCode={r.rating_code}
                summaryText={r.summary_text}
                editable={canWrite && (r.status === 'draft' || r.status === 'self_review')}
            />

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
                        <span className="text-gray-600 mr-1">{t('reviews.probationOutcome')}:</span>
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
