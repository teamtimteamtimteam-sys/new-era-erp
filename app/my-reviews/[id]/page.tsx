// app/my-reviews/[id]/page.tsx
// 评估文档(评估人视角)。字段契约:评估人看得见除薪酬外的一切 —— 所以这一页
// 【压根没有薪酬段】,也没有 HR 的决定表单(试用期结论是 HR 的,set_review_conclusion
// 刻意不收它)。写入走 HR-3d 前置切的评估人函数,每一道闸在 DB。
// 不是这一行的评估人 → notFound(持 HR 权限的去 /hr/reviews/[id] 看)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import GoalsEditor from '@/app/hr/reviews/GoalsEditor'
import ConclusionForm, { type RatingOption } from '@/app/hr/reviews/ConclusionForm'
import ReviewActions from '@/app/hr/reviews/ReviewActions'
import {
    REVIEW_COLUMNS,
    type GoalRow,
    type ReviewRow,
    statusPillClass,
} from '@/app/hr/reviews/reviewShared'

export default async function MyReviewDetailPage({ params }: { params: Promise<{ id: string }> }) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    // 失败不能被读成"这不是你的评估"—— 那是把故障说成越权,而且它决定 canWrite
    const meRes = await supabase.rpc('current_user_employee')
    const me = mustOne(meRes, 'current_user_employee')
    const reviewRes = await supabase
        .from('performance_reviews_masked')
        .select(REVIEW_COLUMNS)
        .eq('id', id)
        .maybeSingle()
    const reviewRow = mustOne(reviewRes, 'performance_reviews_masked')
    if (!me || !reviewRow) notFound()
    const r = reviewRow as unknown as ReviewRow
    if (r.reviewer_employee_id !== me) notFound()

    const [goalsRes, ratingRes, subjectRes, userRes, canHrEdit] = await Promise.all([
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
        supabase.from('my_review_subjects').select('*').eq('review_id', id).maybeSingle(),
        supabase.auth.getUser(),
        can('module.hr.edit'),
    ])

    const goals = mustRows(goalsRes, 'review_goals') as unknown as GoalRow[]
    const ratings = mustRows(ratingRes, 'review_rating_scale') as unknown as RatingOption[]
    const subject = mustOne(subjectRes, 'my_review_subjects') as unknown as {
        employee_code: string
        employee_name: string
        job_title: string | null
        department_name_en: string | null
        department_name_zh: string | null
        cycle_name: string | null
    } | null
    const uid = userRes.data.user?.id ?? null
    const isSubmitter = r.submitted_by !== null && r.submitted_by === uid

    return (
        <div className="p-8 max-w-6xl">
            <Link href="/my-reviews" className="text-sm text-blue-600 hover:underline">
                {t('common.back')}
            </Link>

            <h1 className="text-2xl font-bold mt-2 mb-1">
                {subject?.employee_name ?? t('reviews.detailTitle')}
                <span className="ml-2 font-mono text-base text-gray-500">{subject?.employee_code}</span>
                <span className={'ml-3 align-middle inline-block rounded px-2 py-0.5 text-xs ' + statusPillClass(r.status)}>
                    {t(`reviews.status_${r.status}`)}
                </span>
            </h1>
            {subject?.job_title && (
                <p className="text-sm text-gray-600 mb-4">
                    {subject.job_title}
                    {(locale === 'zh' ? subject.department_name_zh : subject.department_name_en)
                        ? ` · ${locale === 'zh' ? subject.department_name_zh : subject.department_name_en}`
                        : ''}
                </p>
            )}

            <div className="bg-gray-50 rounded p-4 mb-6 grid grid-cols-2 md:grid-cols-3 gap-x-8 gap-y-2 text-sm">
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.type')}:</span>
                    {t(`reviews.type_${r.review_type}`)}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.cycle')}:</span>
                    {subject?.cycle_name ?? '—'}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('reviews.period')}:</span>
                    <span className="font-mono">{r.period_start} → {r.period_end}</span>
                </div>
            </div>

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

            <h2 className="text-xl font-bold mb-3">{t('reviews.goalsTitle')}</h2>
            <GoalsEditor
                reviewId={r.id}
                goals={goals}
                canEditGoals={r.status === 'draft'}
                canAssess={r.status === 'draft' || r.status === 'self_review'}
                canSetActual={r.status === 'draft' || r.status === 'submitted'}
            />

            <h2 className="text-xl font-bold mb-3">{t('reviews.conclusionTitle')}</h2>
            <ConclusionForm
                reviewId={r.id}
                ratings={ratings}
                ratingCode={r.rating_code}
                summaryText={r.summary_text}
                editable={r.status === 'draft' || r.status === 'self_review'}
            />

            {r.review_type === 'probation' && (
                <div className="mb-6 text-sm">
                    <span className="text-gray-600 mr-1">{t('reviews.probationOutcome')}:</span>
                    {r.probation_outcome ? t(`reviews.outcome_${r.probation_outcome}`) : '—'}
                </div>
            )}

            <ReviewActions
                reviewId={r.id}
                status={r.status}
                reviewType={r.review_type}
                probationOutcome={r.probation_outcome}
                selfAssessmentLocked={r.self_assessment_submitted_at !== null}
                canWrite={true}
                canHrEdit={canHrEdit}
                isSubmitter={isSubmitter}
            />
        </div>
    )
}
