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
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { CONTROL_INPUT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'

// ════════════════════════════════════════════════════════════════════════════
// ★★【ALERT-2d(2026-09-09):这三个 prop 现在【只装记录状态】,不装权限】★★
// ════════════════════════════════════════════════════════════════════════════
//   改之前 /hr/reviews/[id] 传的是 `canWrite && r.status === 'draft'` ——
//   **一个布尔为假有两个完全不同的原因**,而屏幕上一句都不说。
//   `DBLOCK-CONFLATED-BOOLEANS` 拿的正是这一行当样板:给"状态不对"写一句
//   权限的话,就是把人支去要一项他可能早就有的权限。
//
//   现在两半各归各:
//     · 权限那一半 → 页面用 `<PermissionGate>` 包住整个编辑器
//       (看得见、按不动、点名 `module.hr.edit`,并且带上【另一条路】:
//        你是不是这份考核点名的评估人 —— 那条路管理员开不了);
//     · 记录状态那一半 → 就是下面这三个 prop,外加 `stateNote` 那一句话。
//   ☞ /my-reviews/[id] 一直就是这么传的(纯状态),所以两个调用点从此同形。
type Props = {
    reviewId: string
    goals: GoalRow[]
    /** 【只是记录状态】draft:目标行的增删改(objective/target/unit) */
    canEditGoals: boolean
    /** 【只是记录状态】draft/self_review:逐条评语 */
    canAssess: boolean
    /** 【只是记录状态】draft/submitted:实际值(自评期归本人) */
    canSetActual: boolean
    /**
     * 记录状态那一半的【一句话】:这份考核现在是什么状态、于是目标改不动。
     * CMP-2 的房规 —— 一个非瞬态的禁用条件要有一行紧邻的、看得见的解释。
     * 由页面给整句(它才知道状态名怎么念),组件不拼字符串。
     */
    stateNote?: string | null
}

const inp = `${CONTROL_INPUT} w-full`
const ta = `${CONTROL_TEXTAREA} w-full`

export default function GoalsEditor({ reviewId, goals, canEditGoals, canAssess, canSetActual, stateNote }: Props) {
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
                            <th className="border border-gray-300 px-2 py-1 text-right tabular-nums">{t('reviews.colTarget')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-2 py-1 text-left">{t('reviews.colUnit')}</th>
                            <th className="border border-gray-300 px-2 py-1 text-right tabular-nums">{t('reviews.colActual')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-2 py-1 text-left">{t('reviews.colEmployeeResult')}</th>
                            <th className="hidden sm:table-cell border border-gray-300 px-2 py-1 text-left">{t('reviews.colAssessment')}</th>
                            {editable && <th className="hidden sm:table-cell border border-gray-300 px-2 py-1 w-28"></th>}
                        </tr>
                    </thead>
                    <tbody>
                        {goals.map((g) => {
                            const on = editing === g.id
                            /* ★ TABLE-PHONE-3:同一组控件要在两个断点各画一次(桌面档在自己那一列,
                               手机档叠在「目标」格里),所以提到这里定义一次 —— 免得两处日后走散。
                               动作一个字没改:还是同一个 save / begin / remove。 */
                            const actionControls = (
                                <>
                                {on ? (
                                    <>
                                        <Button
                                            variant="link"
                                            size="inline"
                                            type="button"
                                            onClick={() => save(g)}
                                            disabled={pending || draftUnitMissing}
                                            className="mr-2"
                                        >
                                            {t('common.save')}
                                        </Button>
                                        <Button
                                            variant="secondary"
                                            type="button"
                                            onClick={() => { setEditing(null); setDraft(null) }}
                                        >
                                            {t('common.cancel')}
                                        </Button>
                                        {draftUnitMissing && (
                                            <p className="text-xs text-red-700 mt-1">{t('reviews.unitRequired')}</p>
                                        )}
                                    </>
                                ) : (
                                    <>
                                        <Button
                                            variant="link"
                                            size="inline"
                                            type="button"
                                            onClick={() => begin(g)}
                                            className="mr-2"
                                        >
                                            {t('reviews.edit')}
                                        </Button>
                                        {/* ★★ ALERT-2a:这一处【此前没有任何确认步骤,而它是一次硬删除】★★
                                            `removeGoal` → `app/hr/reviews/actions.ts:68`
                                            → rpc `remove_review_goal`
                                            → `DELETE FROM review_goals`。**行没了。**
                                            ☞ ALERT-2a 的委托书把它归进了「说 Delete 其实是软删」那一族,
                                              并要给它挂上 `common.softDeleteNote`(「数据保留…可以恢复」)——
                                              **那句话在这里是假的**,而在一个一按就永久销毁的钮上
                                              印一句"可以恢复",比什么都不说更坏。闸上更正,归到这一族。
                                            ☞ 动作一个字没改:同一个 `remove(g.id)`。 */}
                                        {canEditGoals && (
                                            <ConfirmButton
                                                subject={g.objective_text}
                                                title={t('reviews.goalDeleteTitle')}
                                                body={t('common.hardDeleteNote')}
                                                details={
                                                    <p className="text-sm font-medium text-foreground">
                                                        {t('reviews.goalDeleteConsequence')}
                                                    </p>
                                                }
                                                confirmLabel={t('common.delete')}
                                                tier="destructive"
                                                disabled={pending}
                                                triggerVariant="destructive"
                                                triggerSize="inline"
                                                onConfirm={() => remove(g.id)}
                                            >
                                                {t('common.delete')}
                                            </ConfirmButton>
                                        )}
                                    </>
                                )}
                                </>
                            )
                            return (
                                <tr key={g.id} className="align-top">
                                    <td className="border border-gray-300 px-2 py-1 text-gray-500">{g.sequence}</td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        {on && canEditGoals ? (
                                            <textarea
                                                value={draft!.objective}
                                                onChange={(e) => setDraft({ ...draft!, objective: e.target.value })}
                                                className={ta}
                                            />
                                        ) : (
                                            <span className="whitespace-pre-wrap">{g.objective_text}</span>
                                        )}
                                        {/* ★ TABLE-PHONE-3:手机档被拿掉的列(单位 / 本人小结 / 评价,
                                            以及那一列【桌面档本来就没有列头】的动作),原样叠在这里,
                                            各带各的列头 —— 拿掉的是那一列,不是那个事实。
                                            指标与实绩留在列上:少了任何一个,另一个都判断不了。 */}
                                        <div className="sm:hidden mt-1 space-y-1 text-xs text-gray-600">
                                            <div>
                                                <span className="text-gray-500">{t('reviews.colUnit')}: </span>
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
                                            </div>
                                            <div>
                                                <span className="text-gray-500">{t('reviews.colEmployeeResult')}: </span>
                                                <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>
                                            </div>
                                            <div>
                                                <span className="text-gray-500">{t('reviews.colAssessment')}: </span>
                                                {on && canAssess ? (
                                                    <textarea
                                                        value={draft!.assessment}
                                                        onChange={(e) => setDraft({ ...draft!, assessment: e.target.value })}
                                                        className={ta}
                                                    />
                                                ) : (
                                                    <span className="whitespace-pre-wrap">{g.reviewer_assessment_text ?? '—'}</span>
                                                )}
                                            </div>
                                            {/* 这一条【没有标签,而它在桌面档也没有】—— 钮面上自己带着字
                                                (common.save / common.cancel / reviews.edit / common.delete),
                                                所以这里【不另造一句话】。 */}
                                            {editable && <div>{actionControls}</div>}
                                        </div>
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1 text-right font-mono">
                                        {on && canEditGoals ? (
                                            <input
                                                type="number"
                                                value={draft!.target}
                                                onChange={(e) => setDraft({ ...draft!, target: e.target.value })}
                                                className={`${inp} text-right w-20 tabular-nums`}
                                            />
                                        ) : (
                                            g.target_value ?? '—'
                                        )}
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1">
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
                                                className={`${inp} text-right w-20 tabular-nums`}
                                            />
                                        ) : (
                                            g.actual_value ?? '—'
                                        )}
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1">
                                        <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>
                                    </td>
                                    <td className="hidden sm:table-cell border border-gray-300 px-2 py-1">
                                        {on && canAssess ? (
                                            <textarea
                                                value={draft!.assessment}
                                                onChange={(e) => setDraft({ ...draft!, assessment: e.target.value })}
                                                className={ta}
                                            />
                                        ) : (
                                            <span className="whitespace-pre-wrap">{g.reviewer_assessment_text ?? '—'}</span>
                                        )}
                                    </td>
                                    {editable && (
                                        <td className="hidden sm:table-cell border border-gray-300 px-2 py-1 whitespace-nowrap">
                                            {actionControls}
                                        </td>
                                    )}
                                </tr>
                            )
                        })}
                    </tbody>
                </table>
            )}

            {/* ★ ALERT-2d:`canEditGoals` 为假时这一块【原本整个消失,一个字都没有】。
                   它今天为假只剩一个原因(记录状态),所以就地说出那个原因 ——
                   而不是让"这份考核已经提交了"和"这个功能不存在"在屏幕上长得一样。 */}
            {!canEditGoals && stateNote && (
                <p className="text-sm text-gray-600" data-state-note="goals">{stateNote}</p>
            )}
            {canEditGoals && (
                <div className="rounded border border-gray-200 p-4">
                    <h3 className="mb-1">{t('reviews.addGoal')}</h3>
                    {/* 指标与单位一起定:此刻不填单位,以后就没有任何一条路能补上它 */}
                    <p className="text-xs text-gray-500 mb-3">{t('reviews.addGoalHint')}</p>
                    <div className="flex gap-2 flex-wrap items-end">
                        <label className="grow min-w-64">
                            {t('reviews.colObjective')}
                            <textarea
                                value={newObjective}
                                onChange={(e) => setNewObjective(e.target.value)}
                                className={`block ${ta}`}
                            />
                        </label>
                        <label className="">
                            {t('reviews.colTarget')}
                            <input
                                type="number"
                                value={newTarget}
                                onChange={(e) => setNewTarget(e.target.value)}
                                className={`block ${inp} w-24 text-right tabular-nums`}
                            />
                        </label>
                        <label className="">
                            {t('reviews.colUnit')}
                            <input
                                value={newUnit}
                                onChange={(e) => setNewUnit(e.target.value)}
                                placeholder="% / kg / 天"
                                className={`block ${inp} w-24`}
                            />
                        </label>
                        <Button
                            type="button"
                            onClick={add}
                            disabled={pending || newObjective.trim() === '' || newUnitMissing}
                        >
                            {t('common.save')}
                        </Button>
                    </div>
                    {newUnitMissing && <p className="text-xs text-red-700 mt-2">{t('reviews.unitRequired')}</p>}
                </div>
            )}
        </div>
    )
}
