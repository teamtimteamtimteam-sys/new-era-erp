'use client'

// 自评面板。只在有评估处于 self_review 时出现;读的是 HR-3c 的两个窄视图
// (my_self_assessment / my_self_assessment_goals)—— 目标、指标、单位与
// 【自己写的】结果;评级、评语、结论在视图的 SELECT 里根本不存在。
// 定稿(final)即锁死:再改要评估人重开。这句话在按钮旁边说,不在报错里说。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveSelfAssessment } from '@/app/hr/reviews/actions'

export type SelfAssessment = {
    review_id: string
    review_type: string
    cycle_name: string | null
    period_start: string
    period_end: string
    self_assessment_text: string | null
    self_assessment_submitted_at: string | null
}

export type SelfAssessmentGoal = {
    goal_id: string
    review_id: string
    sequence: number
    objective_text: string
    target_value: number | null
    unit: string | null
    employee_result_text: string | null
    actual_value: number | null
}

export default function MySelfAssessmentPanel({
    assessments,
    goals,
}: {
    assessments: SelfAssessment[]
    goals: SelfAssessmentGoal[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [text, setText] = useState<Record<string, string>>(() =>
        Object.fromEntries(assessments.map((a) => [a.review_id, a.self_assessment_text ?? '']))
    )
    const [results, setResults] = useState<Record<string, { result: string; actual: string }>>(() =>
        Object.fromEntries(
            goals.map((g) => [
                g.goal_id,
                {
                    result: g.employee_result_text ?? '',
                    actual: g.actual_value === null ? '' : String(g.actual_value),
                },
            ])
        )
    )

    function save(a: SelfAssessment, final: boolean) {
        setError(null)
        startTransition(async () => {
            const goalResults = goals
                .filter((g) => g.review_id === a.review_id)
                .map((g) => ({
                    goal_id: g.goal_id,
                    result_text: results[g.goal_id]?.result ?? null,
                    actual_value:
                        (results[g.goal_id]?.actual ?? '').trim() === ''
                            ? null
                            : Number(results[g.goal_id].actual),
                }))
            const r = await saveSelfAssessment(a.review_id, text[a.review_id] ?? '', goalResults, final)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    const inp = 'w-full border border-gray-300 rounded px-2 py-1 text-sm'

    return (
        <section className="mb-6">
            <h2 className="text-lg font-bold mb-2">{t('reviews.selfPanelTitle')}</h2>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {assessments.map((a) => {
                const locked = a.self_assessment_submitted_at !== null
                const myGoals = goals.filter((g) => g.review_id === a.review_id)
                return (
                    <div key={a.review_id} className="rounded border border-blue-200 bg-blue-50/40 p-4 mb-4">
                        <div className="flex items-baseline justify-between mb-3 flex-wrap gap-2">
                            <div className="text-sm font-medium">
                                {t(`reviews.type_${a.review_type}`)}
                                {a.cycle_name && <span className="ml-2">{a.cycle_name}</span>}
                                <span className="ml-2 font-mono text-xs text-gray-500">
                                    {a.period_start} → {a.period_end}
                                </span>
                            </div>
                            {locked && (
                                <span className="rounded bg-green-100 text-green-800 px-2 py-0.5 text-xs">
                                    {t('reviews.selfSubmitted')}
                                </span>
                            )}
                        </div>

                        <table className="w-full border-collapse text-sm mb-3">
                            <thead>
                                <tr className="bg-gray-50 text-left">
                                    <th className="border border-gray-300 px-2 py-1 w-8">#</th>
                                    <th className="border border-gray-300 px-2 py-1">{t('reviews.colObjective')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colTarget')}</th>
                                    <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colActual')}</th>
                                    <th className="border border-gray-300 px-2 py-1">{t('reviews.colEmployeeResult')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {myGoals.map((g) => (
                                    <tr key={g.goal_id} className="align-top">
                                        <td className="border border-gray-300 px-2 py-1 text-gray-500">{g.sequence}</td>
                                        <td className="border border-gray-300 px-2 py-1 whitespace-pre-wrap">{g.objective_text}</td>
                                        <td className="border border-gray-300 px-2 py-1 text-right font-mono whitespace-nowrap">
                                            {g.target_value !== null ? `${g.target_value} ${g.unit ?? ''}` : '—'}
                                        </td>
                                        <td className="border border-gray-300 px-2 py-1 text-right">
                                            {locked ? (
                                                <span className="font-mono">
                                                    {g.actual_value !== null ? `${g.actual_value} ${g.unit ?? ''}` : '—'}
                                                </span>
                                            ) : (
                                                <span className="inline-flex items-center gap-1">
                                                    <input
                                                        type="number"
                                                        value={results[g.goal_id]?.actual ?? ''}
                                                        onChange={(e) =>
                                                            setResults({
                                                                ...results,
                                                                [g.goal_id]: { ...results[g.goal_id], actual: e.target.value },
                                                            })
                                                        }
                                                        className="w-24 border border-gray-300 rounded px-1 py-0.5 text-xs text-right"
                                                        disabled={g.unit === null}
                                                        title={g.unit === null ? t('reviews.noUnitNoNumber') : undefined}
                                                    />
                                                    <span className="text-xs text-gray-500">{g.unit ?? ''}</span>
                                                </span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-2 py-1">
                                            {locked ? (
                                                <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>
                                            ) : (
                                                <textarea
                                                    value={results[g.goal_id]?.result ?? ''}
                                                    onChange={(e) =>
                                                        setResults({
                                                            ...results,
                                                            [g.goal_id]: { ...results[g.goal_id], result: e.target.value },
                                                        })
                                                    }
                                                    className="w-full border border-gray-300 rounded px-1 py-0.5 text-xs min-h-14"
                                                />
                                            )}
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>

                        <label className="text-xs text-gray-600 block mb-3">
                            {t('reviews.selfText')}
                            {locked ? (
                                <p className="text-sm text-gray-900 whitespace-pre-wrap mt-1">
                                    {a.self_assessment_text ?? '—'}
                                </p>
                            ) : (
                                <textarea
                                    value={text[a.review_id] ?? ''}
                                    onChange={(e) => setText({ ...text, [a.review_id]: e.target.value })}
                                    className={`block mt-1 ${inp} min-h-24`}
                                />
                            )}
                        </label>

                        {locked ? (
                            <p className="text-xs text-gray-500">{t('reviews.selfLockedHint')}</p>
                        ) : (
                            <div className="flex gap-2 items-center flex-wrap">
                                <button
                                    type="button"
                                    onClick={() => save(a, false)}
                                    disabled={pending}
                                    className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
                                >
                                    {pending ? t('common.saving') : t('common.save')}
                                </button>
                                <button
                                    type="button"
                                    onClick={() => save(a, true)}
                                    disabled={pending}
                                    className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm disabled:opacity-50"
                                >
                                    {t('reviews.selfFinalize')}
                                </button>
                                <span className="text-xs text-gray-500">{t('reviews.selfFinalizeHint')}</span>
                            </div>
                        )}
                    </div>
                )
            })}
        </section>
    )
}
