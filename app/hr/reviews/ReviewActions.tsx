'use client'

// 状态流按钮。【永远不把注定失败的按钮画出来】:
// - 批准按钮对提交人不渲染 —— approve_review 反正会拒(SELF_APPROVAL_FORBIDDEN),
//   一个一按就报错的按钮比没有按钮更糟。
// - 批准之前把话说在前面:批准后的评估不能改,只能作废重开。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { approveReview, openSelfAssessment, submitReview, voidReview } from './actions'
import { Button } from '@/app/components/ui/button'

type Props = {
    reviewId: string
    status: string
    reviewType: string
    probationOutcome: string | null
    selfAssessmentLocked: boolean
    canWrite: boolean // 本行的评估人,或 module.hr.edit
    canHrEdit: boolean
    isSubmitter: boolean // submitted_by === 当前账号
}

export default function ReviewActions({
    reviewId,
    status,
    reviewType,
    probationOutcome,
    selfAssessmentLocked,
    canWrite,
    canHrEdit,
    isSubmitter,
}: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [voidReason, setVoidReason] = useState('')

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    const preApproval = status === 'draft' || status === 'self_review' || status === 'submitted'
    const btn = 'border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm disabled:opacity-50'

    return (
        <div className="mb-8">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            {/* 批准是终点站:改动只能靠作废重开 —— 这句话要在批准【之前】读到 */}
            {preApproval && (canWrite || canHrEdit) && (
                <p className="text-xs text-gray-500 mb-3">{t('reviews.approvalIsFinal')}</p>
            )}

            <div className="flex gap-2 flex-wrap items-center">
                {canWrite && (status === 'draft' || status === 'self_review') && (
                    <>
                        <Button variant="secondary" size="sm"
                            type="button"
                            onClick={() => run(() => openSelfAssessment(reviewId))}
                            disabled={pending}>
                            {status === 'self_review' && selfAssessmentLocked
                                ? t('reviews.reopenSelfAssessment')
                                : t('reviews.openSelfAssessment')}
                        </Button>
                        <button
                            type="button"
                            onClick={() => run(() => submitReview(reviewId))}
                            disabled={pending}
                            className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm disabled:opacity-50"
                        >
                            {t('reviews.submit')}
                        </button>
                    </>
                )}

                {status === 'submitted' && canHrEdit && !isSubmitter && (
                    <Button size="sm"
                        type="button"
                        onClick={() => run(() => approveReview(reviewId))}
                        disabled={pending}>
                        {t('reviews.approve')}
                    </Button>
                )}
            </div>

            {/* 提交人不给批准按钮,但要说清为什么没有 —— 四眼原则 */}
            {status === 'submitted' && canHrEdit && isSubmitter && (
                <p className="text-xs text-amber-800 mt-2">{t('reviews.fourEyes')}</p>
            )}

            {/* 评估人写不了试用期结论 —— 提交前提醒去找 HR,免得一按就 PROBATION_OUTCOME_REQUIRED */}
            {reviewType === 'probation' &&
                probationOutcome === null &&
                (status === 'draft' || status === 'self_review') &&
                canWrite &&
                !canHrEdit && (
                    <p className="text-xs text-amber-800 mt-2">{t('reviews.probationOutcomePendingHr')}</p>
                )}

            {canHrEdit && status !== 'void' && (
                <div className="flex gap-2 items-end mt-4">
                    <label className="text-xs text-gray-600">
                        {t('reviews.voidReason')}
                        <input
                            value={voidReason}
                            onChange={(e) => setVoidReason(e.target.value)}
                            className="block border border-gray-300 rounded px-2 py-1 text-sm w-64"
                        />
                    </label>
                    <Button variant="destructive" size="sm"
                        type="button"
                        onClick={() => run(() => voidReview(reviewId, voidReason))}
                        disabled={pending || voidReason.trim() === ''}>
                        {t('reviews.void')}
                    </Button>
                </div>
            )}
        </div>
    )
}
