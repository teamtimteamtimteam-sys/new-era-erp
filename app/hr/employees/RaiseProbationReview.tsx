'use client'

// app/hr/employees/RaiseProbationReview.tsx
// PROBATION-1:试用期转正评估的【那扇门】。
//
// ★【为什么它在员工档案页,而不是在 /hr 的告警列表上】★
// /hr 的告警行本来就链到 `/hr/employees/{id}` —— 人已经被送到这里了。
// 而发起一份转正评估是一件【带着雇佣后果】的动作(批准之后会改 employment_status、
// 写 confirmation_date、留一行履历),它该在当事人的档案摊开在眼前的时候做,
// 不该是在一张列表上点一个按钮、连这个人是谁都没看见。
//
// ★【为什么这个控件在"还没有任何评估"的时候【也要】渲染】★
// 员工页原来整节写着 `{empReviews.length > 0 && (...)}` —— 一份评估都没有时,
// 整节【什么都不显示】。而"一份都没有"恰恰是唯一需要这扇门的时候。
// **那个 length > 0 本身就是这扇门缺席的一部分**,所以本刀把它拆开:
// 表格仍然按有无渲染,门按【这个人在不在试用期】渲染。
//
// 【服务端另有一道】按钮只在看起来能按的时候出现,而 open_probation_review
// 自己会拒(EMPLOYEE_NOT_ON_PROBATION / PROBATION_END_DATE_NOT_SET / …)——
// 绕开界面也过不去。少了后一半,这里只是装饰。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { raiseProbationReview } from '@/app/hr/reviews/actions'
import { useTranslations } from '@/lib/i18n/client'

export default function RaiseProbationReview({
    employeeId,
    probationEndDate,
}: {
    employeeId: string
    probationEndDate: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    // 【命名的缺席,不是一个变灰的按钮】没有到期日时不是"按不动",
    // 而是【说出来为什么按不动,以及去哪儿补】—— 一个没有理由的禁用控件,
    // 读的人只会以为是权限问题(docs/silent-disable-inventory.md 那一族)。
    if (!probationEndDate) {
        return (
            <div className="mb-6 rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-900">
                <p className="font-bold">{t('reviews.raiseProbationBlockedTitle')}</p>
                <p className="mt-1">{t('reviews.raiseProbationNoEndDate')}</p>
            </div>
        )
    }

    return (
        <div className="mb-6">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            <button
                type="button"
                disabled={pending}
                onClick={() =>
                    startTransition(async () => {
                        setError(null)
                        const r = await raiseProbationReview(employeeId)
                        if (r.error) setError(r.error)
                        else if (r.reviewId) router.push(`/hr/reviews/${r.reviewId}`)
                        else router.refresh()
                    })
                }
                className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm disabled:opacity-50"
            >
                {t('reviews.raiseProbation')}
            </button>
            <p className="text-xs text-gray-500 mt-2">
                {t('reviews.raiseProbationHint', { date: probationEndDate })}
            </p>
        </div>
    )
}
