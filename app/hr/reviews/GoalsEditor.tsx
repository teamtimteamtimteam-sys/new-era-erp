'use client'

// 目标行编辑器。/hr/reviews/[id] 与 /my-reviews/[id] 共用 —— 谁能改哪几列由
// 服务端页面按状态与身份算好递进来,DB 函数仍会各自把关。
//
// 【target 与 unit 一起给】新增与编辑都把指标和单位摆在同一行:
// 一条没有单位的目标之后【永远】填不进数字 —— 约束会拒,而两条写实际值的路
// (save_self_assessment / set_goal_actual_value)都碰不到 unit。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { addGoal, removeGoal, setGoalActual, setGoalAssessment, updateGoal } from './actions'
import type { GoalRow } from './reviewShared'

type Props = {
    reviewId: string
    goals: GoalRow[]
    canEditGoals: boolean // draft:目标行的增删改(objective/target/unit)
    canAssess: boolean // draft/self_review:逐条评语
    canSetActual: boolean // draft/submitted:实际值(自评期归本人)
}

const inp = 'w-full border border-gray-300 rounded px-1 py-0.5 text-xs'

export default function GoalsEditor({ reviewId, goals, canEditGoals, canAssess, canSetActual }: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)

    const [editing, setEditing] = useState<string | null>(null)
    const [draft, setDraft] = useState<{
        objective: string
        target: string
        unit: string
        actual: string
        assessment: string
    } | null>(null)

    const [newObjective, setNewObjective] = useState('')
    const [newTarget, setNewTarget] = useState('')
    const [newUnit, setNewUnit] = useState('')

    const editable = canEditGoals || canAssess || canSetActual

    function begin(g: GoalRow) {
        setEditing(g.id)
        setError(null)
        setDraft({
            objective: g.objective_text,
            target: g.target_value === null ? '' : String(g.target_value),
            unit: g.unit ?? '',
            actual: g.actual_value === null ? '' : String(g.actual_value),
            assessment: g.reviewer_assessment_text ?? '',
        })
    }

    // 编辑态里数字/单位是否配套(约束 review_goals_unit_required 的镜像)
    const draftUnitMissing =
        !!draft && (draft.target.trim() !== '' || draft.actual.trim() !== '') && draft.unit.trim() === ''
    const newUnitMissing = newTarget.trim() !== '' && newUnit.trim() === ''

    function save(g: GoalRow) {
        if (!draft) return
        setError(null)
        startTransition(async () => {
            // 只把改动过且当前身份写得动的部分递给对应的函数
            if (canEditGoals) {
                const target = draft.target.trim() === '' ? null : Number(draft.target)
                const unit = draft.unit.trim() === '' ? null : draft.unit.trim()
                if (
                    draft.objective !== g.objective_text ||
                    target !== g.target_value ||
                    unit !== (g.unit ?? null)
                ) {
                    const r = await updateGoal(reviewId, g.id, draft.objective, target, unit)
                    if (r.error) { setError(r.error); return }
                }
            }
            if (canSetActual) {
                const actual = draft.actual.trim() === '' ? null : Number(draft.actual)
                if (actual !== g.actual_value) {
                    const r = await setGoalActual(reviewId, g.id, actual)
                    if (r.error) { setError(r.error); return }
                }
            }
            if (canAssess && draft.assessment !== (g.reviewer_assessment_text ?? '')) {
                const r = await setGoalAssessment(reviewId, g.id, draft.assessment)
                if (r.error) { setError(r.error); return }
            }
            setEditing(null)
            setDraft(null)
            router.refresh()
        })
    }

    function remove(goalId: string) {
        setError(null)
        startTransition(async () => {
            const r = await removeGoal(reviewId, goalId)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    function add() {
        setError(null)
        startTransition(async () => {
            const target = newTarget.trim() === '' ? null : Number(newTarget)
            const unit = newUnit.trim() === '' ? null : newUnit.trim()
            const r = await addGoal(reviewId, newObjective, target, unit)
            if (r.error) setError(r.error)
            else {
                setNewObjective(''); setNewTarget(''); setNewUnit('')
                router.refresh()
            }
        })
    }

    return (
        <div className="mb-6">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            {goals.length === 0 ? (
                <p className="text-sm text-gray-500 mb-3">{t('reviews.noGoals')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm mb-3">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-2 py-1 text-left w-8">#</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.colObjective')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colTarget')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.colUnit')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right">{t('reviews.colActual')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.colEmployeeResult')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-left">{t('reviews.colAssessment')}</th>
                            {editable && <th className="border border-gray-300 px-2 py-1 w-28"></th>}
                        </tr>
                    </thead>
                    <tbody>
                        {goals.map((g) => {
                            const on = editing === g.id
                            return (
                                <tr key={g.id} className="align-top">
                                    <td className="border border-gray-300 px-2 py-1 text-gray-500">{g.sequence}</td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        {on && canEditGoals ? (
                                            <textarea
                                                value={draft!.objective}
                                                onChange={(e) => setDraft({ ...draft!, objective: e.target.value })}
                                                className={`${inp} min-h-16`}
                                            />
                                        ) : (
                                            <span className="whitespace-pre-wrap">{g.objective_text}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                        {on && canEditGoals ? (
                                            <input
                                                type="number"
                                                value={draft!.target}
                                                onChange={(e) => setDraft({ ...draft!, target: e.target.value })}
                                                className={`${inp} text-right w-20`}
                                            />
                                        ) : (
                                            g.target_value ?? '—'
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        {on && canEditGoals ? (
                                            <input
                                                value={draft!.unit}
                                                onChange={(e) => setDraft({ ...draft!, unit: e.target.value })}
                                                placeholder={t('reviews.colUnit')}
                                                className={`${inp} w-16`}
                                            />
                                        ) : (
                                            g.unit ?? '—'
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                        {on && canSetActual ? (
                                            <input
                                                type="number"
                                                value={draft!.actual}
                                                onChange={(e) => setDraft({ ...draft!, actual: e.target.value })}
                                                className={`${inp} text-right w-20`}
                                            />
                                        ) : (
                                            g.actual_value ?? '—'
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        {on && canAssess ? (
                                            <textarea
                                                value={draft!.assessment}
                                                onChange={(e) => setDraft({ ...draft!, assessment: e.target.value })}
                                                className={`${inp} min-h-16`}
                                            />
                                        ) : (
                                            <span className="whitespace-pre-wrap">{g.reviewer_assessment_text ?? '—'}</span>
                                        )}
                                    </td>
                                    {editable && (
                                        <td className="border border-gray-300 px-2 py-1 whitespace-nowrap">
                                            {on ? (
                                                <>
                                                    <button
                                                        type="button"
                                                        onClick={() => save(g)}
                                                        disabled={pending || draftUnitMissing}
                                                        className="text-blue-600 hover:underline mr-2 disabled:opacity-50"
                                                    >
                                                        {t('common.save')}
                                                    </button>
                                                    <button
                                                        type="button"
                                                        onClick={() => { setEditing(null); setDraft(null) }}
                                                        className="text-gray-500 hover:underline"
                                                    >
                                                        {t('common.cancel')}
                                                    </button>
                                                    {draftUnitMissing && (
                                                        <p className="text-xs text-red-700 mt-1">{t('reviews.unitRequired')}</p>
                                                    )}
                                                </>
                                            ) : (
                                                <>
                                                    <button
                                                        type="button"
                                                        onClick={() => begin(g)}
                                                        className="text-blue-600 hover:underline mr-2"
                                                    >
                                                        {t('reviews.edit')}
                                                    </button>
                                                    {canEditGoals && (
                                                        <button
                                                            type="button"
                                                            onClick={() => remove(g.id)}
                                                            disabled={pending}
                                                            className="text-red-600 hover:underline"
                                                        >
                                                            {t('common.delete')}
                                                        </button>
                                                    )}
                                                </>
                                            )}
                                        </td>
                                    )}
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            {canEditGoals && (
                <div className="rounded border border-gray-200 p-4">
                    <h3 className="font-bold mb-1 text-sm">{t('reviews.addGoal')}</h3>
                    {/* 指标与单位一起定:此刻不填单位,以后就没有任何一条路能补上它 */}
                    <p className="text-xs text-gray-500 mb-3">{t('reviews.addGoalHint')}</p>
                    <div className="flex gap-2 flex-wrap items-end">
                        <label className="text-xs grow min-w-64">
                            {t('reviews.colObjective')}
                            <textarea
                                value={newObjective}
                                onChange={(e) => setNewObjective(e.target.value)}
                                className={`block ${inp} min-h-16`}
                            />
                        </label>
                        <label className="text-xs">
                            {t('reviews.colTarget')}
                            <input
                                type="number"
                                value={newTarget}
                                onChange={(e) => setNewTarget(e.target.value)}
                                className={`block ${inp} w-24 text-right`}
                            />
                        </label>
                        <label className="text-xs">
                            {t('reviews.colUnit')}
                            <input
                                value={newUnit}
                                onChange={(e) => setNewUnit(e.target.value)}
                                placeholder="% / kg / 天"
                                className={`block ${inp} w-24`}
                            />
                        </label>
                        <button
                            type="button"
                            onClick={add}
                            disabled={pending || newObjective.trim() === '' || newUnitMissing}
                            className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50"
                        >
                            {t('common.save')}
                        </button>
                    </div>
                    {newUnitMissing && <p className="text-xs text-red-700 mt-2">{t('reviews.unitRequired')}</p>}
                </div>
            )}
        </div>
    )
}
