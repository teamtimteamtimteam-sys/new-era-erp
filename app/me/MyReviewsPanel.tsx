'use client'

// 自己的评估:【只有批准之后的】(approved / acknowledged)—— 行级策略如此,
// 这里读得到的每一行都已经是定论。评级、评语、结论、试用期结论、以及
// 【自己的】调薪(遮蔽视图对本人让路)都完整可见;确认已阅走 acknowledge_review,
// 只有本人能按,HR 没有代按的口子。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import { acknowledgeReview } from '@/app/hr/reviews/actions'
import type { GoalRow, ReviewRow } from '@/app/hr/reviews/reviewShared'
import type { RatingOption } from '@/app/hr/reviews/ConclusionForm'

export default function MyReviewsPanel({
    reviews,
    goals,
    ratings,
}: {
    reviews: ReviewRow[]
    goals: GoalRow[]
    ratings: RatingOption[]
}) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const ratingName = (code: string | null) => {
        if (!code) return '—'
        const r = ratings.find((x) => x.code === code)
        return r ? (locale === 'zh' ? r.name_zh : r.name_en) : code
    }

    function ack(reviewId: string) {
        setError(null)
        startTransition(async () => {
            const r = await acknowledgeReview(reviewId)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    return (
        <section className="mb-6">
            <h2 className="text-lg font-bold mb-2">{t('reviews.mineTitle')}</h2>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {reviews.map((r) => {
                const myGoals = goals.filter((g) => g.review_id === r.id)
                return (
                    <details key={r.id} className="rounded border border-gray-200 mb-3">
                        <summary className="cursor-pointer px-4 py-3 text-sm flex items-baseline gap-3 flex-wrap">
                            <span className="font-medium">{t(`reviews.type_${r.review_type}`)}</span>
                            <span className="font-mono text-xs text-gray-500">
                                {r.period_start} → {r.period_end}
                            </span>
                            <span className="font-medium">{ratingName(r.rating_code)}</span>
                            {r.status === 'approved' ? (
                                <span className="rounded bg-amber-100 text-amber-800 px-2 py-0.5 text-xs">
                                    {t('reviews.awaitingAck')}
                                </span>
                            ) : (
                                <span className="rounded bg-green-100 text-green-800 px-2 py-0.5 text-xs">
                                    {t('reviews.status_acknowledged')}
                                </span>
                            )}
                        </summary>
                        <div className="px-4 pb-4">
                            {r.summary_text && (
                                <p className="text-sm whitespace-pre-wrap mb-3">{r.summary_text}</p>
                            )}

                            {myGoals.length > 0 && (
                                <table className="w-full border-collapse text-sm mb-3">
                                    <thead>
                                        <tr className="bg-gray-50 text-left">
                                            <th className="border border-gray-300 px-2 py-1">{t('reviews.colObjective')}</th>
                                            <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colTarget')}</th>
                                            <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colActual')}</th>
                                            <th className="border border-gray-300 px-2 py-1">{t('reviews.colEmployeeResult')}</th>
                                            <th className="border border-gray-300 px-2 py-1">{t('reviews.colAssessment')}</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        {myGoals.map((g) => (
                                            <tr key={g.id} className="align-top">
                                                <td className="border border-gray-300 px-2 py-1 whitespace-pre-wrap">{g.objective_text}</td>
                                                <td className="border border-gray-300 px-2 py-1 text-right font-mono whitespace-nowrap">
                                                    {g.target_value !== null ? `${g.target_value} ${g.unit ?? ''}` : '—'}
                                                </td>
                                                <td className="border border-gray-300 px-2 py-1 text-right font-mono whitespace-nowrap">
                                                    {g.actual_value !== null ? `${g.actual_value} ${g.unit ?? ''}` : '—'}
                                                </td>
                                                <td className="border border-gray-300 px-2 py-1 whitespace-pre-wrap">{g.employee_result_text ?? '—'}</td>
                                                <td className="border border-gray-300 px-2 py-1 whitespace-pre-wrap">{g.reviewer_assessment_text ?? '—'}</td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            )}

                            <div className="flex gap-6 flex-wrap text-sm mb-3">
                                {r.review_type === 'probation' && (
                                    <div>
                                        <span className="text-gray-600 mr-1">{t('reviews.probationOutcome')}:</span>
                                        {r.probation_outcome ? t(`reviews.outcome_${r.probation_outcome}`) : '—'}
                                    </div>
                                )}
                                {r.new_monthly_salary !== null && (
                                    <div>
                                        <span className="text-gray-600 mr-1">{t('reviews.newSalary')}:</span>
                                        <span className="font-mono">{r.new_monthly_salary}</span>
                                        {r.salary_effective_date && (
                                            <span className="ml-2 text-gray-500">
                                                {t('reviews.salaryEffective')} {r.salary_effective_date}
                                            </span>
                                        )}
                                    </div>
                                )}
                            </div>

                            {r.status === 'approved' && (
                                <button
                                    type="button"
                                    onClick={() => ack(r.id)}
                                    disabled={pending}
                                    className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50"
                                >
                                    {t('reviews.acknowledge')}
                                </button>
                            )}
                        </div>
                    </details>
                )
            })}
        </section>
    )
}
