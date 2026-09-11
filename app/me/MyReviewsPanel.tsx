'use client'

// 自己的评估:【只有批准之后的】(approved / acknowledged)—— 行级策略如此,
// 这里读得到的每一行都已经是定论。评级、评语、结论、试用期结论、以及
// 【自己的】调薪(遮蔽视图对本人让路)都完整可见;确认已阅走 acknowledge_review,
// 只有本人能按,HR 没有代按的口子。
//
// ★ TABLE-CONVERT-1(2026-09-10):目标那张手搓表格 → 组件。
//   【手机上留哪几列一个字没改】TABLE-PHONE-3 留的是:目标 · 指标 · 实绩
//   (这张表没有状态列,第三格就给第二个要紧的数 —— 只有实绩没有指标判断不了),
//   折起来的是:本人小结 · 评价。转换把「留」写成 priority,「折」写成不带。
//   ★ 空态【原样保留成外面那道 myGoals.length > 0 的闸】:这张表本来就
//     「没有目标就整张不画」,而不是画一张写着"空"的表。空态的 prop 会多出
//     一句今天不存在的话 —— 搬一句没有的话不是搬,是加。
//   ★ align-top 从 <tr> 搬到了每一列的 className:组件的格子钉死 align-middle,
//     而 cn() 里调用方排在最后。目标那一格是 whitespace-pre-wrap 的多行文字,
//     居中对齐会让它和右边两个数字错开 —— 那是当时写下 align-top 的原因。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useLocale, useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { acknowledgeReview } from '@/app/hr/reviews/actions'
import type { GoalRow, ReviewRow } from '@/app/hr/reviews/reviewShared'
import type { RatingOption } from '@/app/hr/reviews/ConclusionForm'
import { Button } from '@/app/components/ui/button'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export default function MyReviewsPanel({
    reviews,
    goals,
    ratings,
    baseCurrency,
}: {
    reviews: ReviewRow[]
    goals: GoalRow[]
    ratings: RatingOption[]
    /** 调薪的月薪是本位币,而这块面板上没有任何一处写着币种 —— 由页面读
     *  currencies.is_base 传进来(客户端组件拿不到,也不许猜) */
    baseCurrency: string
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

    // ★ 一份列定义给所有周期共用 —— 它只依赖 t,不依赖某一次评估。
    const columns: Column<GoalRow>[] = [
        {
            key: 'objective', header: t('reviews.colObjective'), priority: true,
            className: 'align-top whitespace-pre-wrap',
            render: (g) => g.objective_text,
        },
        {
            key: 'target', header: t('reviews.colTarget'), align: 'right', priority: true,
            className: 'align-top font-mono whitespace-nowrap',
            render: (g) => (g.target_value !== null ? `${g.target_value} ${g.unit ?? ''}` : '—'),
        },
        {
            key: 'actual', header: t('reviews.colActual'), align: 'right', priority: true,
            className: 'align-top font-mono whitespace-nowrap',
            render: (g) => (g.actual_value !== null ? `${g.actual_value} ${g.unit ?? ''}` : '—'),
        },
        {
            key: 'employeeResult', header: t('reviews.colEmployeeResult'),
            className: 'align-top whitespace-pre-wrap',
            render: (g) => g.employee_result_text ?? '—',
        },
        {
            key: 'assessment', header: t('reviews.colAssessment'),
            className: 'align-top whitespace-pre-wrap',
            render: (g) => g.reviewer_assessment_text ?? '—',
        },
    ]

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
            <h2 className="mb-2">{t('reviews.mineTitle')}</h2>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {reviews.map((r) => {
                const myGoals = goals.filter((g) => g.review_id === r.id)
                return (
                    <details key={r.id} className="rounded border border-gray-200 mb-3">
                        <summary className="cursor-pointer px-4 py-3 text-sm flex items-baseline gap-3 flex-wrap">
                            <span className="font-medium">{t(`reviews.type_${r.review_type}`)}</span>
                            <span className="font-mono text-xs text-[color:var(--brand-muted-text)]">
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
                                <div className="mb-3">
                                    <DataTable
                                        rows={myGoals}
                                        columns={columns}
                                        rowKey={(g) => g.id}
                                        phone={{ mode: 'columns' }}
                                    />
                                </div>
                            )}

                            <div className="flex gap-6 flex-wrap text-sm mb-3">
                                {r.review_type === 'probation' && (
                                    <div>
                                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.probationOutcome')}:</span>
                                        {r.probation_outcome ? t(`reviews.outcome_${r.probation_outcome}`) : '—'}
                                    </div>
                                )}
                                {r.new_monthly_salary !== null && (
                                    <div>
                                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('reviews.newSalary')}:</span>
                                        <span className="font-mono">
                                            {formatAmount(r.new_monthly_salary, baseCurrency)}
                                        </span>
                                        {r.salary_effective_date && (
                                            <span className="ml-2 text-[color:var(--brand-muted-text)]">
                                                {t('reviews.salaryEffective')} {r.salary_effective_date}
                                            </span>
                                        )}
                                    </div>
                                )}
                            </div>

                            {r.status === 'approved' && (
                                <Button
                                    type="button"
                                    onClick={() => ack(r.id)}
                                    disabled={pending}>
                                    {t('reviews.acknowledge')}
                                </Button>
                            )}
                        </div>
                    </details>
                )
            })}
        </section>
    )
}
