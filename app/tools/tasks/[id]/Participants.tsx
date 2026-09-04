'use client'

import { useState, useTransition } from 'react'
import { addParticipant, removeParticipant, promoteToTeam, correctType } from './actions'

// app/tools/tasks/[id]/Participants.tsx
// TASK-1b:参与者面板。
//
// 【用词是有约束的:「已退出 / 已移出」,绝不写「移除」】
// 移出【不是取消分享】—— 前参与者仍然读得到这张任务(他的编辑在记录里,
// 把他贡献过的东西藏起来读起来像抹掉)。一个承诺了系统做不到的事的词,
// 正是这个仓库反复点名的那种缺陷。真要让谁看不到,答案是另建一张任务。
//
// 【「改回私人」这扇门只在它还开着的时候出现】。有别人来过之后它就永远关上了,
// 而关上之后类型只是一段文字 —— 不提供一个注定失败的手势。

// 【列都是可空的,因为它们来自视图】—— 生成的类型如实反映了这一点,
// 这里就照着写,而不是把不一致强转掉。渲染处各自决定"没有值时说什么"。
export type ParticipantRow = {
    participant_id: string | null
    employee_id: string | null
    display_name: string | null
    added_at: string | null
    added_by_name: string | null
    removed_at: string | null
    left_voluntarily: boolean | null
}
export type AssignableRow = { employee_id: string | null; display_name: string | null; code: string | null }

type Labels = {
    heading: string; empty: string; add: string; pick: string
    left: string; removed: string; removeOther: string; leave: string
    addedBy: string; stillReads: string; correctType: string; typeLocked: string
    noAssignPermission: string; nobodyEligible: string
}

export default function Participants({
    taskId, rows, assignable, mayAssign, canEdit, myEmployeeId, correctable, labels,
}: {
    taskId: string; rows: ParticipantRow[]; assignable: AssignableRow[]
    // 【权限自己回答能不能看】,不由 assignable 是不是空来倒推
    mayAssign: boolean
    canEdit: boolean; myEmployeeId: string | null; correctable: boolean; labels: Labels
}) {
    const [error, setError] = useState<string | null>(null)
    const [pick, setPick] = useState('')
    const [pending, start] = useTransition()

    const run = (fn: () => Promise<{ error: string } | { success: true }>) =>
        start(async () => {
            const res = await fn()
            setError('error' in res ? res.error : null)
        })

    const active = rows.filter((r) => !r.removed_at)
    const past = rows.filter((r) => r.removed_at)
    const onIt = new Set(active.map((r) => r.employee_id).filter(Boolean))

    return (
        <section className="mt-8 border-t pt-6">
            <h2 className="mb-3 text-xl font-bold">{labels.heading}</h2>

            {error ? (
                <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            ) : null}

            {active.length === 0 ? <p className="text-sm text-gray-500">{labels.empty}</p> : null}
            <ul className="text-sm">
                {active.map((r) => (
                    <li key={r.participant_id ?? r.employee_id} className="flex items-center gap-3 py-1">
                        <span>{r.display_name}</span>
                        {r.added_by_name ? (
                            <span className="text-xs text-gray-500">{labels.addedBy} {r.added_by_name}</span>
                        ) : null}
                        {canEdit ? (
                            <button
                                className="ml-auto text-xs text-red-700"
                                disabled={pending || !r.participant_id}
                                onClick={() => run(() => removeParticipant(taskId, r.participant_id as string))}
                            >
                                {r.employee_id === myEmployeeId ? labels.leave : labels.removeOther}
                            </button>
                        ) : null}
                    </li>
                ))}
            </ul>

            {past.length > 0 ? (
                <>
                    <p className="mt-4 text-xs text-gray-500">{labels.stillReads}</p>
                    <ul className="text-sm text-gray-500">
                        {past.map((r) => (
                            <li key={r.participant_id ?? r.employee_id} className="py-1">
                                {r.display_name} — {r.left_voluntarily ? labels.left : labels.removed}
                            </li>
                        ))}
                    </ul>
                </>
            ) : null}

            {/* TASK-1c-b STEP 4:【三种状态,三句不同的话】。
                以前这里只有"有没有行"两种,于是"你不被允许看"与"没有人可选"
                长成了同一个空下拉 —— 空集不是答案(lib/permissions.ts 的立身之本)。 */}
            {canEdit && !mayAssign ? (
                <p className="mt-4 text-sm text-gray-600">{labels.noAssignPermission}</p>
            ) : null}

            {canEdit && mayAssign && assignable.filter((a) => a.employee_id && !onIt.has(a.employee_id)).length === 0 ? (
                <p className="mt-4 text-sm text-gray-600">{labels.nobodyEligible}</p>
            ) : null}

            {canEdit && mayAssign && assignable.filter((a) => a.employee_id && !onIt.has(a.employee_id)).length > 0 ? (
                <div className="mt-4 flex flex-wrap items-center gap-2">
                    <select
                        className="rounded border px-2 py-1 text-sm"
                        value={pick}
                        onChange={(e) => setPick(e.target.value)}
                    >
                        <option value="">{labels.pick}</option>
                        {assignable
                            .filter((a) => a.employee_id && !onIt.has(a.employee_id))
                            .map((a) => (
                                <option key={a.employee_id as string} value={a.employee_id as string}>
                                    {a.display_name}
                                </option>
                            ))}
                    </select>
                    <button
                        className="rounded bg-blue-600 px-2 py-1 text-xs text-white disabled:opacity-50"
                        disabled={pending || !pick}
                        onClick={() => { run(() => addParticipant(taskId, pick)); setPick('') }}
                    >{labels.add}</button>
                </div>
            ) : null}

            {/* TASK-1c-c:【控件不再静默消失】。服务端会拒绝时,它渲染成禁用的,
                理由写在屏幕上 —— 与 PromotePanel 给 Team 那一项的处理同一套,
                不另写第二套。一个消失了的控件说不出"为什么不能",
                而那正是 Tim 卡住的地方:他看到的不是拒绝,是【什么都没有】。 */}
            <div className="mt-4">
                {correctable ? null : (
                    <p className="mb-2 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
                        {labels.typeLocked}
                    </p>
                )}
                <button
                    className="text-xs text-gray-700 underline disabled:no-underline disabled:text-gray-400"
                    disabled={pending || !correctable}
                    onClick={() => run(() => correctType(taskId))}
                >
                    {labels.correctType}
                </button>
            </div>
        </section>
    )
}

export function PromoteButton({ taskId, label, disabled = false }: { taskId: string; label: string; disabled?: boolean }) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    return (
        <>
            {error ? (
                <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            ) : null}
            <button
                className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50"
                disabled={pending || disabled}
                onClick={() =>
                    start(async () => {
                        const res = await promoteToTeam(taskId)
                        setError('error' in res ? res.error : null)
                    })
                }
            >{label}</button>
        </>
    )
}
