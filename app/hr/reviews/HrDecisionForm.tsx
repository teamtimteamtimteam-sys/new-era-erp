'use client'

// HR 的决定列:试用期结论与调薪。这两样【刻意】不在评估人的写入面里
// (set_review_conclusion 不收它们),所以只在 module.hr.edit 之下渲染。
//
// 【not_confirm 不办离职】屏幕上就把话说全:决定只是被记下来了,
// 通知期、最后一个月的工资、状态改动都还是手工流程 —— 否则 HR 点完就以为人走完了。
//
// 【调薪两列一起交】没有生效日的新工资无法过账(performance_reviews_salary_shape)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveHrDecision } from './actions'
import { Button } from '@/app/components/ui/button'

type Props = {
    reviewId: string
    reviewType: string
    probationOutcome: string | null
    newMonthlySalary: number | null
    salaryEffectiveDate: string | null
    canPay: boolean // data.view_pay:薪酬段整个只对持码人渲染
    editable: boolean // 批准之前(draft / self_review / submitted)
}

export default function HrDecisionForm({
    reviewId,
    reviewType,
    probationOutcome,
    newMonthlySalary,
    salaryEffectiveDate,
    canPay,
    editable,
}: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [outcome, setOutcome] = useState(probationOutcome ?? '')
    const [salary, setSalary] = useState(newMonthlySalary === null ? '' : String(newMonthlySalary))
    const [effective, setEffective] = useState(salaryEffectiveDate ?? '')

    const salaryHalf =
        (salary.trim() === '') !== (effective.trim() === '') // 一半有一半没有

    function save() {
        setError(null)
        startTransition(async () => {
            const decision: Parameters<typeof saveHrDecision>[1] = {}
            if (reviewType === 'probation') decision.probation_outcome = outcome === '' ? null : outcome
            if (canPay) {
                decision.new_monthly_salary = salary.trim() === '' ? null : Number(salary)
                decision.salary_effective_date = effective.trim() === '' ? null : effective
            }
            const r = await saveHrDecision(reviewId, decision)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    const showProbation = reviewType === 'probation'
    if (!showProbation && !canPay) return null

    return (
        <div className="mb-6 rounded border border-gray-200 p-4">
            <h3 className="font-bold mb-3 text-sm">{t('reviews.hrDecisionTitle')}</h3>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-4 flex-wrap items-end">
                {showProbation && (
                    <label className="text-xs text-gray-600">
                        {t('reviews.probationOutcome')}
                        {editable ? (
                            <select
                                value={outcome}
                                onChange={(e) => setOutcome(e.target.value)}
                                className="block border border-gray-300 rounded px-2 py-1 text-sm"
                            >
                                <option value="">—</option>
                                <option value="confirm">{t('reviews.outcome_confirm')}</option>
                                <option value="not_confirm">{t('reviews.outcome_not_confirm')}</option>
                            </select>
                        ) : (
                            <span className="block text-sm text-gray-900 py-1">
                                {probationOutcome ? t(`reviews.outcome_${probationOutcome}`) : '—'}
                            </span>
                        )}
                    </label>
                )}

                {/* 薪酬段:只对持 data.view_pay 的人渲染(不渲染灰框,整段不出现) */}
                {canPay && (
                    <>
                        <label className="text-xs text-gray-600">
                            {t('reviews.newSalary')}
                            {editable ? (
                                <input
                                    type="number"
                                    value={salary}
                                    onChange={(e) => setSalary(e.target.value)}
                                    className="block border border-gray-300 rounded px-2 py-1 text-sm w-32 text-right font-mono"
                                />
                            ) : (
                                <span className="block text-sm py-1 font-mono">
                                    {newMonthlySalary ?? '—'}
                                </span>
                            )}
                        </label>
                        <label className="text-xs text-gray-600">
                            {t('reviews.salaryEffective')}
                            {editable ? (
                                <input
                                    type="date"
                                    value={effective}
                                    onChange={(e) => setEffective(e.target.value)}
                                    className="block border border-gray-300 rounded px-2 py-1 text-sm"
                                />
                            ) : (
                                <span className="block text-sm py-1 font-mono">{salaryEffectiveDate ?? '—'}</span>
                            )}
                        </label>
                    </>
                )}

                {editable && (
                    <Button size="sm"
                        type="button"
                        onClick={save}
                        disabled={pending || salaryHalf}
                    >
                        {pending ? t('common.saving') : t('common.save')}
                    </Button>
                )}
            </div>
            {salaryHalf && editable && (
                <p className="text-xs text-red-700 mt-2">{t('reviews.salaryPairRequired')}</p>
            )}

            {/* not_confirm ≠ 离职:通知、最后一个月工资、状态改动都还是手工流程 */}
            {showProbation && (editable ? outcome === 'not_confirm' : probationOutcome === 'not_confirm') && (
                <div className="mt-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                    {t('reviews.notConfirmManual')}
                </div>
            )}
        </div>
    )
}
