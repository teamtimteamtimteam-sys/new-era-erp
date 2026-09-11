'use client'

// HR 的决定列:试用期结论与调薪。这两样【刻意】不在评估人的写入面里
// (set_review_conclusion 不收它们),所以只在 module.hr.edit 之下渲染。
//
// 【not_confirm 不办离职】屏幕上就把话说全:决定只是被记下来了,
// 通知期、最后一个月的工资、状态改动都还是手工流程 —— 否则 HR 点完就以为人走完了。
//
// 【调薪两列一起交】没有生效日的新工资无法过账(performance_reviews_salary_shape)。
import { CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveHrDecision } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'

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
    // ════════════════════════════════════════════════════════════════════════
    // ★★★【ALERT-2d(2026-09-09)· 这里原本是 `if (!showProbation && !canPay)
    //      return null` —— DBLOCK-1 裁定的【最坏的一种】】★★★
    // ════════════════════════════════════════════════════════════════════════
    //   两个操作数,两类东西,而普查把它算进了桶 ④:
    //     · `showProbation = reviewType === 'probation'` —— **记录状态**
    //       (判据那条 `\bstate\b` 认不出 `reviewType`,所以它被判成 OTHER;
    //        它其实是这份考核【是哪一种】,一条不折不扣的记录属性);
    //     · `canPay = data.view_pay` —— **权限**,而且是一个【数据类】权限。
    //   合起来为假时整块面板 `return null`:一个只做年度考核、又没有看薪权限的
    //   HR,屏幕上【连"这里本来有一块 HR 的决定"都读不到】。
    //   **一个藏起来的东西教给人的是"这个功能不存在"。**
    //
    //   现在:面板恒画。
    //     · 试用期结论那一格 —— 只有 probation 型考核才有,这是记录状态,
    //       年度考核里它本来就【不存在】,不是被挡住(所以不给它一句拒绝);
    //     · 薪酬那两格 —— 走 <PermissionGate>(点名 data.view_pay),
    //       而值本身画成【受限】药丸,不是空白。
    //       **空白读作"没定过工资",受限读作"你看不到"** —— 本仓库
    //       lib/permissions.ts 整个存在的理由就是这一句。

    return (
        <div className="mb-6 rounded border border-gray-200 p-4">
            <h3 className="mb-3">{t('reviews.hrDecisionTitle')}</h3>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-4 flex-wrap items-end">
                {showProbation && (
                    <label className="">
                        {t('reviews.probationOutcome')}
                        {editable ? (
                            <select
                                value={outcome}
                                onChange={(e) => setOutcome(e.target.value)}
                                className={`${CONTROL_SELECT} block`}
                            >
                                <option value="">—</option>
                                <option value="confirm">{t('reviews.outcome_confirm')}</option>
                                <option value="not_confirm">{t('reviews.outcome_not_confirm')}</option>
                            </select>
                        ) : (
                            <span className="block text-sm text-[color:var(--brand-text)] py-1">
                                {probationOutcome ? t(`reviews.outcome_${probationOutcome}`) : '—'}
                            </span>
                        )}
                    </label>
                )}

                {/* 薪酬段:ALERT-2d 之前是【只对持 data.view_pay 的人渲染,整段不出现】。
                    现在整段照画,值画成「受限」,控件看得见按不动并点名那个码。 */}
                {!canPay && (
                    <PermissionGate code="data.view_pay" allowed={false} inline>
                        <label className="">
                            {t('reviews.newSalary')}
                            <span className="block py-1">
                                <Refusal why={t('common.dataClassDeniedHint')}>{t('common.restricted')}</Refusal>
                            </span>
                        </label>
                    </PermissionGate>
                )}
                {canPay && (
                    <>
                        <label className="">
                            {t('reviews.newSalary')}
                            {editable ? (
                                <input
                                    type="number"
                                    value={salary}
                                    onChange={(e) => setSalary(e.target.value)}
                                    className={`${CONTROL_INPUT} block w-32 text-right font-mono`}
                                />
                            ) : (
                                <span className="block text-sm py-1 font-mono">
                                    {newMonthlySalary ?? '—'}
                                </span>
                            )}
                        </label>
                        <label className="">
                            {t('reviews.salaryEffective')}
                            {editable ? (
                                <input
                                    type="date"
                                    value={effective}
                                    onChange={(e) => setEffective(e.target.value)}
                                    className={`${CONTROL_INPUT} block`}
                                />
                            ) : (
                                <span className="block text-sm py-1 font-mono">{salaryEffectiveDate ?? '—'}</span>
                            )}
                        </label>
                    </>
                )}

                {editable && (
                    <Button
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
