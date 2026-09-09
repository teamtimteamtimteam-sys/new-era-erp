'use client'

// 状态流按钮。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【ALERT-2d(2026-09-09)· 抬头那句话被 DBLOCK-1 推翻过,这里同步更正】★★
// ════════════════════════════════════════════════════════════════════════════
//   原文写的是「永远不把注定失败的按钮画出来」。**DBLOCK-1 已经把它改成:
//   一个注定被拒的控件要【看得见、按不动、并且说出原因】** ——
//   藏起来的钮教给人的是"这个功能不存在",看得见的钮教给人的是"该去要什么"。
//   AGENTS.md 那一段(“must not offer it ≠ must not show it”)是权威原文。
//
//   本刀按【为什么按不动】把这三处分开:
//     · 缺权限        → `<PermissionGate>`:看得见、按不动、点名权限码;
//     · 这份考核的状态不对 → 一句话,说出它现在是什么状态、什么状态才能做;
//     · 「是你提交的」  → 四眼原则那一句(它本来就在,只是原先还要求 canHrEdit,
//        于是一个没有 HR 权限的提交人什么都读不到)。
//   ☞ 三种原因三句话 —— 这正是 DBLOCK-CONFLATED-BOOLEANS 立案要的东西:
//     "说错原因比不说原因更坏"。
//
// - 批准之前把话说在前面:批准后的评估不能改,只能作废重开。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { approveReview, openSelfAssessment, submitReview, voidReview } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

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

    // ★【记录状态那一半,单独命名】—— 它此前和 canWrite 挤在同一个 && 里。
    const stateAllowsFlow = status === 'draft' || status === 'self_review'
    const statusName = t(`reviews.status_${status}`)

    // ★【另一条路】`canWrite = canHrEdit || isReviewer`,而 isReviewer 是一次
    //   【关系授权】:管理员勾不出来它。只说 module.hr.edit 会把人支去要一样
    //   要来了也未必管用的东西 —— 见 permission-gate.tsx 抬头的 alsoAllowedIf。
    const orReviewer = {
        label: t('reviews.gate.orReviewer'),
        why: t('reviews.gate.orReviewerWhy'),
    }

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
                {/* ★★ ALERT-2d ①:`canWrite && (status==='draft'||status==='self_review')`
                       拆成两半。**先问记录状态,再问权限** —— 一份已经批准的考核
                       对【任何人】都开不了自评,那时再补一句"你还需要某项权限"
                       是一句正确而无用的话(要它也没用)。所以状态不对时只说状态。 */}
                {!stateAllowsFlow ? (
                    <p className="text-sm text-gray-600" data-state-note="flow">
                        {t('reviews.stateFlowLocked', { 0: statusName })}
                    </p>
                ) : (
                    <PermissionGate code="module.hr.edit" allowed={canWrite} alsoAllowedIf={orReviewer} inline>
                        <Button variant="secondary" size="sm"
                            type="button"
                            onClick={() => run(() => openSelfAssessment(reviewId))}
                            disabled={pending}>
                            {status === 'self_review' && selfAssessmentLocked
                                ? t('reviews.reopenSelfAssessment')
                                : t('reviews.openSelfAssessment')}
                        </Button>
                        <Button
                            type="button"
                            onClick={() => run(() => submitReview(reviewId))}
                            disabled={pending}
                            variant="default" size="sm"
                        >
                            {t('reviews.submit')}
                        </Button>
                    </PermissionGate>
                )}

                {/* ★★ ALERT-2d ④(c):三个操作数、三类东西 ——
                       `status === 'submitted'`(记录状态)· `canHrEdit`(权限)·
                       `!isSubmitter`(【是不是你提交的】,既非权限也非记录状态)。
                       第三类那一句本来就在下面,只是它原先还要求 canHrEdit ——
                       于是一个【没有 HR 权限的提交人】三句话一句都读不到。 */}
                {status === 'submitted' && !isSubmitter && (
                    <PermissionGate code="module.hr.edit" allowed={canHrEdit} inline>
                        <Button size="sm"
                            type="button"
                            onClick={() => run(() => approveReview(reviewId))}
                            disabled={pending}>
                            {t('reviews.approve')}
                        </Button>
                    </PermissionGate>
                )}
            </div>

            {/* 提交人不给批准按钮,但要说清为什么没有 —— 四眼原则。
                ★ ALERT-2d:去掉了 `canHrEdit &&`。四眼原则对提交人成立,
                  与他有没有 HR 权限无关;带着那个条件,没有权限的提交人
                  屏幕上一个字都没有。 */}
            {status === 'submitted' && isSubmitter && (
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

            {/* ★★ ALERT-2d ①:`canHrEdit && status !== 'void'` 拆成两半。
                   已经作废的考核【谁都作废不了第二次】,所以那时只说状态;
                   还没作废时,缺的就只是权限 —— 看得见、按不动、点名那个码。
                   ☞ 这里【不带】alsoAllowedIf:作废真的只有 module.hr.edit 一条路,
                     评估人开不了它。写一条不存在的第二条路,与写错原因是同一种坏。 */}
            {status === 'void' ? (
                <p className="mt-4 text-sm text-gray-600" data-state-note="void">
                    {t('reviews.stateAlreadyVoid')}
                </p>
            ) : (
                <PermissionGate code="module.hr.edit" allowed={canHrEdit} className="mt-4 flex w-full items-stretch">
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
                </PermissionGate>
            )}
        </div>
    )
}
