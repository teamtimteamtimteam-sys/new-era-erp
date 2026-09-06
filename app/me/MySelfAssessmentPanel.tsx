'use client'

// 自评面板。只在有评估处于 self_review 时出现;读的是 HR-3c 的两个窄视图
// (my_self_assessment / my_self_assessment_goals)—— 目标、指标、单位与
// 【自己写的】结果;评级、评语、结论在视图的 SELECT 里根本不存在。
// 定稿(final)即锁死:再改要评估人重开。这句话在按钮旁边说,不在报错里说。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【CONV-2:这一页是本刀【最硬的那个例子】,而它逼出了模板的一个槽】★★
//
//   前两页(假别 / 评级档位)是账簿:一次改一行,那一行自己保存。
//   **这一页不是账簿,它是一张【长得像表格的表单】** —— 三件事让它不一样:
//     ① 每一行开局就可以改,没有「编辑」钮(mode='all-rows');
//     ② 那一次提交【不属于这张表】:它同时带着表格【外面】那段自评正文;
//     ③ 它有【两个】提交(存草稿 / 定稿),而定稿是不可逆的。
//
//   于是组件不能拥有那次保存 —— 但它拥有草稿。**footer 槽就是为此存在的:
//   把草稿递出去,页面在那里画自己的提交区。**
//   ☞ 这与 CONV-1 的 notices 槽同源:两个槽都不是设计出来的,
//     都是在【第四页之内】被一个真实页面撞出来的。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'
import { saveSelfAssessment } from '@/app/hr/reviews/actions'
import { Button } from '@/app/components/ui/button'

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

/** 一行的草稿:自己填的实际值与结果说明。两者都是字符串 —— 空串就是"没填"。 */
type GoalDraft = { result: string; actual: string }

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
    // 表格【外面】那一段正文 —— 它不属于任何一行,所以留在页面自己手里。
    const [text, setText] = useState<Record<string, string>>(() =>
        Object.fromEntries(assessments.map((a) => [a.review_id, a.self_assessment_text ?? '']))
    )

    const inp = 'w-full border border-gray-300 rounded px-2 py-1 text-sm'

    function save(a: SelfAssessment, drafts: Readonly<Record<string, GoalDraft>>, final: boolean) {
        setError(null)
        startTransition(async () => {
            const goalResults = goals
                .filter((g) => g.review_id === a.review_id)
                .map((g) => ({
                    goal_id: g.goal_id,
                    result_text: drafts[g.goal_id]?.result ?? null,
                    actual_value:
                        (drafts[g.goal_id]?.actual ?? '').trim() === ''
                            ? null
                            : Number(drafts[g.goal_id].actual),
                }))
            const r = await saveSelfAssessment(a.review_id, text[a.review_id] ?? '', goalResults, final)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    function columnsFor(locked: boolean): EditableColumn<SelfAssessmentGoal, GoalDraft>[] {
        return [
            {
                key: 'seq',
                header: '#',
                priority: true,
                className: 'text-gray-500 w-8',
                render: (g) => g.sequence,
            },
            {
                key: 'objective',
                header: t('reviews.colObjective'),
                priority: true,
                className: 'whitespace-pre-wrap',
                render: (g) => g.objective_text,
            },
            {
                key: 'target',
                header: t('reviews.colTarget'),
                align: 'right',
                className: 'font-mono whitespace-nowrap',
                render: (g) => (g.target_value !== null ? `${g.target_value} ${g.unit ?? ''}` : '—'),
            },
            {
                key: 'actual',
                header: t('reviews.colActual'),
                align: 'right',
                render: (g) =>
                    g.actual_value !== null ? (
                        <span className="font-mono">{`${g.actual_value} ${g.unit ?? ''}`}</span>
                    ) : (
                        '—'
                    ),
                // 【定稿之后整表只读】—— locked 时不给 edit,组件就画不出输入框。
                ...(locked ? {} : {
                    edit: (d, set) => (
                        <span className="inline-flex items-center gap-1">
                            <input
                                type="number"
                                value={d.actual}
                                onChange={(e) => set({ actual: e.target.value })}
                                aria-label={t('reviews.colActual')}
                                className="w-24 rounded border border-gray-300 px-1 py-0.5 text-right text-xs"
                            />
                        </span>
                    ),
                }),
            },
            {
                key: 'result',
                header: t('reviews.colEmployeeResult'),
                render: (g) => (
                    <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>
                ),
                ...(locked ? {} : {
                    edit: (d, set) => (
                        <textarea
                            value={d.result}
                            onChange={(e) => set({ result: e.target.value })}
                            aria-label={t('reviews.colEmployeeResult')}
                            className="min-h-14 w-full rounded border border-gray-300 px-1 py-0.5 text-xs"
                        />
                    ),
                }),
            },
        ]
    }

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

                        <EditableTable<SelfAssessmentGoal, GoalDraft>
                            className="mb-3"
                            rows={myGoals}
                            columns={columnsFor(locked)}
                            rowKey={(g) => g.goal_id}
                            phone={{ mode: 'columns' }}
                            // ★ Q3 的第二种模式:每一行开局就带草稿,没有「编辑」钮。
                            //   状态形状与一次一行【完全相同】,只是那个 Record 不再被
                            //   约束到一个键。
                            mode="all-rows"
                            canEdit={!locked}
                            toDraft={(g) => ({
                                result: g.employee_result_text ?? '',
                                actual: g.actual_value === null ? '' : String(g.actual_value),
                            })}
                            labels={{
                                edit: t('common.edit'), save: t('common.save'), saving: t('common.saving'),
                                cancel: t('common.cancel'), unsaved: t('common.unsavedRow'),
                                expand: t('common.expandRow'),
                            }}
                            empty={t('reviews.noGoals')}
                            // ★★ 那个被这一页逼出来的槽 ★★
                            //   提交同时要【表外】那段正文与【两个】不同的按钮,
                            //   所以它不能是组件的 onSave —— 组件把草稿递出来,
                            //   页面在这里画自己的提交区。
                            footer={(drafts) => (
                                <>
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
                                            <Button variant="secondary" size="sm"
                                                type="button"
                                                onClick={() => save(a, drafts, false)}
                                                disabled={pending}>
                                                {pending ? t('common.saving') : t('common.save')}
                                            </Button>
                                            <button
                                                type="button"
                                                onClick={() => save(a, drafts, true)}
                                                disabled={pending}
                                                className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm disabled:opacity-50"
                                            >
                                                {t('reviews.selfFinalize')}
                                            </button>
                                            <span className="text-xs text-gray-500">{t('reviews.selfFinalizeHint')}</span>
                                        </div>
                                    )}
                                </>
                            )}
                        />
                    </div>
                )
            })}
        </section>
    )
}
