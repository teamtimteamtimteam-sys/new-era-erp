'use client'

// 目标行编辑器。/hr/reviews/[id] 与 /my-reviews/[id] 共用 —— 谁能改哪几列由
// 服务端页面按状态与身份算好递进来,DB 函数仍会各自把关。
//
// 【target 与 unit 一起给】新增与编辑都把指标和单位摆在同一行:
// 一条没有单位的目标之后【永远】填不进数字 —— 约束会拒,而两条写实际值的路
// (save_self_assessment / set_goal_actual_value)都碰不到 unit。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★ DRAFT-1(2026-09-21)· 这张表搬到了 `<EditableTable>` 上 ★★
// ════════════════════════════════════════════════════════════════════════════
//   搬家换掉的是【壳】,不是【规矩】—— 三支 action 的分流、按权限分列、
//   「有数字就要有单位」这三件一个字都没改,只是各自挪到了组件给的那个口子上:
//
//     · 三支 action   → `onSave(draft, row)` 里,原样的三段 if(见下);
//     · 按权限分列     → **不给 `edit` 就是这一列不可编辑**(组件抬头写着的那条),
//                        于是 `canEditGoals` / `canSetActual` / `canAssess`
//                        各自决定它那几列给不给 `edit` —— 不再是格子里的三元表达式;
//     · 单位配套校验   → `canSave`(DRAFT-1 的能力 E)。★ 它比从前多做一件事:
//                        **理由跟着钮走**。从前那句 `reviews.unitRequired` 只画在
//                        桌面档的动作格里,390px 上那颗钮按不动而屏幕上一个字都没有;
//                        现在两个断点都印(CMP-2:按不动的钮要说出为什么)。
//     · 删除          → `rowActions`(能力 A)。同一颗 `ConfirmButton`,同一次硬删,
//                        组件只借给它一个位置,不知道它是什么。
//     · 加目标         → `footer`。它本来就在表【外面】,搬家前后都是。
//
//   ★ 顺带收下的两件(**不是本刀的目标,是搬家的副产品**):
//     ① 错误从【页顶一个红 div】变成【那一行下面,带 role="alert"】——
//        这张表此前 `role="alert"` 是 0 个;
//     ② 脏着关标签页会拦一下(组件自带的 `beforeunload`)。
//        ⚠ 它盖不住站内 <Link> 跳走,那是一条声明过的限制(组件抬头 Q7)。
//   ★ 变体 A → variant C:整张表此前是 `border border-gray-300` 的全边框,
//     组件自己的表体就是 variant C 的那一套,所以这件衣服是【跟着搬家免费换的】。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { addGoal, removeGoal, setGoalActual, setGoalAssessment, updateGoal } from './actions'
import type { GoalRow } from './reviewShared'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { CONTROL_INPUT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { EditableTable, type EditableColumn } from '@/app/components/ui/editable-table'

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

type Draft = {
    objective: string
    target: string
    unit: string
    actual: string
    assessment: string
}

const inp = `${CONTROL_INPUT} w-full`
const ta = `${CONTROL_TEXTAREA} w-full`

export default function GoalsEditor({ reviewId, goals, canEditGoals, canAssess, canSetActual, stateNote }: Props) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    // ★ 这个 error 现在只装【加行 / 删行】那两支的失败 —— 逐行保存的失败
    //   由组件画在那一行下面。两者不再共用一个页顶红框。
    const [error, setError] = useState<string | null>(null)

    const [newObjective, setNewObjective] = useState('')
    const [newTarget, setNewTarget] = useState('')
    const [newUnit, setNewUnit] = useState('')

    const editable = canEditGoals || canAssess || canSetActual
    const newUnitMissing = newTarget.trim() !== '' && newUnit.trim() === ''

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

    // ── 列 ──────────────────────────────────────────────────────────────────
    // ★ priority 的那四列 = 今天 390px 上留着的那四列(# · 目标 · 指标 · 实绩)。
    //   指标与实绩一起留:少了任何一个,另一个都判断不了。
    //   单位 / 本人小结 / 评价下到展开区,各带各的标签 —— 拿掉的是那一列,不是那个事实。
    const columns: EditableColumn<GoalRow, Draft>[] = [
        {
            key: 'seq',
            header: '#',
            priority: true,
            className: 'w-8 text-[color:var(--brand-muted-text)]',
            render: (g) => g.sequence,
        },
        {
            key: 'objective',
            header: t('reviews.colObjective'),
            priority: true,
            render: (g) => <span className="whitespace-pre-wrap">{g.objective_text}</span>,
            ...(canEditGoals && {
                edit: (d, set) => (
                    <textarea
                        value={d.objective}
                        aria-label={t('reviews.colObjective')}
                        onChange={(e) => set({ objective: e.target.value })}
                        className={ta}
                    />
                ),
            }),
        },
        {
            key: 'target',
            header: t('reviews.colTarget'),
            priority: true,
            align: 'right',
            render: (g) => g.target_value ?? '—',
            ...(canEditGoals && {
                edit: (d, set) => (
                    <input
                        type="number"
                        value={d.target}
                        aria-label={t('reviews.colTarget')}
                        onChange={(e) => set({ target: e.target.value })}
                        className={`${inp} text-right tabular-nums`}
                    />
                ),
            }),
        },
        {
            key: 'unit',
            header: t('reviews.colUnit'),
            render: (g) => g.unit ?? '—',
            ...(canEditGoals && {
                edit: (d, set) => (
                    <input
                        value={d.unit}
                        aria-label={t('reviews.colUnit')}
                        placeholder={t('reviews.colUnit')}
                        onChange={(e) => set({ unit: e.target.value })}
                        className={inp}
                    />
                ),
            }),
        },
        {
            key: 'actual',
            header: t('reviews.colActual'),
            priority: true,
            align: 'right',
            render: (g) => g.actual_value ?? '—',
            ...(canSetActual && {
                edit: (d, set) => (
                    <input
                        type="number"
                        value={d.actual}
                        aria-label={t('reviews.colActual')}
                        onChange={(e) => set({ actual: e.target.value })}
                        className={`${inp} text-right tabular-nums`}
                    />
                ),
            }),
        },
        {
            // 本人小结:两种身份都改不动它(它走 save_self_assessment),所以没有 edit。
            key: 'employeeResult',
            header: t('reviews.colEmployeeResult'),
            render: (g) => <span className="whitespace-pre-wrap">{g.employee_result_text ?? '—'}</span>,
        },
        {
            key: 'assessment',
            header: t('reviews.colAssessment'),
            render: (g) => <span className="whitespace-pre-wrap">{g.reviewer_assessment_text ?? '—'}</span>,
            ...(canAssess && {
                edit: (d, set) => (
                    <textarea
                        value={d.assessment}
                        aria-label={t('reviews.colAssessment')}
                        onChange={(e) => set({ assessment: e.target.value })}
                        className={ta}
                    />
                ),
            }),
        },
    ]

    return (
        <div className="mb-6">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            <EditableTable<GoalRow, Draft>
                rows={goals}
                columns={columns}
                rowKey={(g) => g.id}
                phone={{ mode: 'columns' }}
                canEdit={editable}
                className="mb-3"
                empty={t('reviews.noGoals')}
                toDraft={(g) => ({
                    objective: g.objective_text,
                    target: g.target_value === null ? '' : String(g.target_value),
                    unit: g.unit ?? '',
                    actual: g.actual_value === null ? '' : String(g.actual_value),
                    assessment: g.reviewer_assessment_text ?? '',
                })}
                labels={{
                    edit: t('reviews.edit'), save: t('common.save'), saving: t('common.saving'),
                    cancel: t('common.cancel'), unsaved: t('common.unsavedRow'), expand: t('common.expandRow'),
                }}
                // ★ 编辑态里数字/单位是否配套(约束 review_goals_unit_required 的镜像)。
                //   能力 E 让这条校验【连着它的理由】一起挂在保存钮上。
                canSave={(d) =>
                    (d.target.trim() !== '' || d.actual.trim() !== '') && d.unit.trim() === ''
                        ? { ok: false, why: t('reviews.unitRequired') }
                        : { ok: true }
                }
                // ★★ 一行散成最多【三支】action —— 原样搬过来的那三段 if。 ★★
                //   只把改动过、且当前身份写得动的那一部分递给对应的函数。
                onSave={async (d, g) => {
                    if (canEditGoals) {
                        const target = d.target.trim() === '' ? null : Number(d.target)
                        const unit = d.unit.trim() === '' ? null : d.unit.trim()
                        if (
                            d.objective !== g.objective_text ||
                            target !== g.target_value ||
                            unit !== (g.unit ?? null)
                        ) {
                            const r = await updateGoal(reviewId, g.id, d.objective, target, unit)
                            if (r.error) return { error: r.error }
                        }
                    }
                    if (canSetActual) {
                        const actual = d.actual.trim() === '' ? null : Number(d.actual)
                        if (actual !== g.actual_value) {
                            const r = await setGoalActual(reviewId, g.id, actual)
                            if (r.error) return { error: r.error }
                        }
                    }
                    if (canAssess && d.assessment !== (g.reviewer_assessment_text ?? '')) {
                        const r = await setGoalAssessment(reviewId, g.id, d.assessment)
                        if (r.error) return { error: r.error }
                    }
                    router.refresh()
                }}
                /* ★★ ALERT-2a:这一处【此前没有任何确认步骤,而它是一次硬删除】★★
                    `removeGoal` → `app/hr/reviews/actions.ts:68` → rpc `remove_review_goal`
                    → `DELETE FROM review_goals`。**行没了。**
                    ☞ ALERT-2a 的委托书把它归进了「说 Delete 其实是软删」那一族,
                      并要给它挂上 `common.softDeleteNote`(「数据保留…可以恢复」)——
                      **那句话在这里是假的**,而在一个一按就永久销毁的钮上
                      印一句"可以恢复",比什么都不说更坏。闸上更正,归到这一族。
                    ☞ 动作一个字没改:同一个 `remove(g.id)`。DRAFT-1 只换了它挂的地方。 */
                rowActions={
                    canEditGoals
                        ? (g, ctx) =>
                              ctx.editing ? null : (
                                  <ConfirmButton
                                      subject={g.objective_text}
                                      title={t('reviews.goalDeleteTitle')}
                                      body={t('common.hardDeleteNote')}
                                      details={
                                          <p className="text-sm font-medium text-[color:var(--brand-text)]">
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
                              )
                        : undefined
                }
                /* ★ 加目标的表单【本来就在表外面】,搬家前后都是。footer 就是它的位置。 */
                footer={() => (
                    <>
                        {/* ★ ALERT-2d:`canEditGoals` 为假时这一块【原本整个消失,一个字都没有】。
                               它今天为假只剩一个原因(记录状态),所以就地说出那个原因 ——
                               而不是让"这份考核已经提交了"和"这个功能不存在"在屏幕上长得一样。 */}
                        {!canEditGoals && stateNote && (
                            <p className="text-sm text-[color:var(--brand-muted-text)]" data-state-note="goals">{stateNote}</p>
                        )}
                        {canEditGoals && (
                            <div className="rounded border border-gray-200 p-4">
                                <h3 className="mb-1">{t('reviews.addGoal')}</h3>
                                {/* 指标与单位一起定:此刻不填单位,以后就没有任何一条路能补上它 */}
                                <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('reviews.addGoalHint')}</p>
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
                    </>
                )}
            />
        </div>
    )
}
