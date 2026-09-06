'use client'

import { useState, useTransition } from 'react'
import { addNode, renameNode, setNodeDate, setNodeDone, removeNode, moveNode } from './actions'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

// app/tools/tasks/[id]/NodeTree.tsx
// TASK-1b:步骤树。一层嵌套 —— 而【做不到的手势这里根本不出现】:
// 子步骤上没有"加子步骤"。底下那条复合外键是兜底,不是这句话本身。
//
// 【三条显示规则,都是"空集"那一类的决定,不要"顺手修好"】
//   * 零步骤:【什么指示都不显示】。不是 0/0,也不是空进度条 ——
//     0/0 读成"全没做"还是"全做完"取决于除法往哪边倒,两个都是编的。
//   * 已完成的步骤【永远不是逾期】。晚做完是关于过去的事实,记在变更记录里
//     (old_done/new_done + changed_at),不是挂在做完的事情上的一个红点。
//   * 没有日期的步骤【永远不是逾期】。对每一个没写日期的步骤唠叨,
//     只会训练人忽略这个标记,于是真正要紧的那几个也被忽略。

export type NodeRow = {
    id: string
    parent_id: string | null
    depth: number
    title: string
    target_date: string | null
    done: boolean
    sort_order: number
    created_at: string
}

type Labels = {
    heading: string; empty: string; add: string; addSub: string
    titlePlaceholder: string; targetDate: string; overdue: string
    remove: string; up: string; down: string
    /** ★ BTN-2:上/下两个钮看得见的只有一个箭头,这两条是读屏念出来的名字。 */
    upLabel: string; downLabel: string
    save: string; cancel: string; rename: string
    // ★ BTN-4:硬删除的确认框 —— 标题 + 那句「无法撤销」。
    deleteNodeTitle: string
    deleteNodeConsequence: string
}

const today = () => new Date().toISOString().slice(0, 10)

export default function NodeTree({
    taskId, nodes, labels,
}: { taskId: string; nodes: NodeRow[]; labels: Labels }) {
    const [error, setError] = useState<string | null>(null)
    const [pending, start] = useTransition()
    const [addingUnder, setAddingUnder] = useState<string | null | undefined>(undefined)
    const [draftTitle, setDraftTitle] = useState('')
    const [draftDate, setDraftDate] = useState('')
    const [editing, setEditing] = useState<string | null>(null)
    const [editTitle, setEditTitle] = useState('')

    const run = (fn: () => Promise<{ error: string } | { success: true }>) =>
        start(async () => {
            const res = await fn()
            setError('error' in res ? res.error : null)
        })

    const tops = nodes.filter((n) => n.parent_id === null)
    const kids = (id: string) => nodes.filter((n) => n.parent_id === id)
    const total = nodes.length
    const doneCount = nodes.filter((n) => n.done).length

    const isOverdue = (n: NodeRow) => !n.done && !!n.target_date && n.target_date < today()

    // ★ BTN-4:`data-node-row` 是给交互探针的把手 —— 这一页上 TaskHeader
    //   也有一个 aria-haspopup="dialog"(它软删【整张任务】),而探针要点的是
    //   【这一行】那个硬删除。没有这个把手,探针只能取第一个匹配,于是它会去
    //   删那张任务 —— 一支删掉别人数据的探针,比一支不存在的探针坏得多。
    const row = (n: NodeRow, isSub: boolean) => (
        <li key={n.id} data-node-row={n.id} className={isSub ? 'ml-8 border-l pl-4' : ''}>
            <div className="flex flex-wrap items-center gap-2 py-1">
                <input
                    type="checkbox"
                    checked={n.done}
                    disabled={pending}
                    onChange={(e) => run(() => setNodeDone(taskId, n.id, e.target.checked))}
                    aria-label={n.title}
                />
                {editing === n.id ? (
                    <>
                        <input
                            className="rounded border px-2 py-1 text-sm"
                            value={editTitle}
                            onChange={(e) => setEditTitle(e.target.value)}
                        />
                        <Button size="xs"
                            disabled={pending}
                            onClick={() => { run(() => renameNode(taskId, n.id, editTitle)); setEditing(null) }}>{labels.save}</Button>
                        <Button variant="secondary" size="xs" onClick={() => setEditing(null)}>{labels.cancel}</Button>
                    </>
                ) : (
                    <span className={n.done ? 'text-gray-400 line-through' : ''}>{n.title}</span>
                )}

                <input
                    type="date"
                    className="rounded border px-1 text-xs"
                    value={n.target_date ?? ''}
                    disabled={pending}
                    aria-label={labels.targetDate}
                    onChange={(e) => run(() => setNodeDate(taskId, n.id, e.target.value || null))}
                />
                {isOverdue(n) ? (
                    <span className="rounded bg-amber-100 px-1 text-xs text-amber-800">{labels.overdue}</span>
                ) : null}

                <span className="ml-auto flex gap-2 text-xs">
                    {/* ★ BTN-2:名字补上了,但【没有】转成 <Button> —— 本文件另外 8 个
                        手写钮是 BTN-3 的,只转这两个只会让这一页更花。Tim 的规矩说的是
                        「不许把没有名字的图标钮转过去」,没有说「必须让它继续没有名字」。 */}
                    <Button variant="secondary" size="inline" aria-label={labels.upLabel} disabled={pending} onClick={() => run(() => moveNode(taskId, n.id, 'up'))}>{labels.up}</Button>
                    <Button variant="secondary" size="inline" aria-label={labels.downLabel} disabled={pending} onClick={() => run(() => moveNode(taskId, n.id, 'down'))}>{labels.down}</Button>
                    <Button variant="secondary" size="inline" disabled={pending} onClick={() => { setEditing(n.id); setEditTitle(n.title) }}>{labels.rename}</Button>
                    {/* 【一层嵌套:子步骤上没有这个按钮】—— 做不到的手势不出现 */}
                    {!isSub ? (
                        <Button variant="secondary" size="inline" disabled={pending} onClick={() => { setAddingUnder(n.id); setDraftTitle(''); setDraftDate('') }}>
                            {labels.addSub}
                        </Button>
                    ) : null}
                    {/* ★★ BTN-4:这一处【此前没有任何确认步骤】★★
                        BTN-3b 给了它破坏档(实线左竖条),让它看起来像它做的事,
                        但**刻意没有加确认框** —— 那一刀的规矩是不许改行为。本刀加。

                        ★【它是全树唯一的硬删除,所以话必须说到这个份上】★
                          `removeNode` → `app/tools/tasks/[id]/actions.ts:90`
                          → `supabase.from('task_nodes').delete()` —— **行没了**。
                          这个系统里其它每一处「删除」都是软删(记录还在、标成已删、
                          删的人和理由都记着),**只有这一处不是**。
                          于是这个对话框是**一个人唯一会被告知这件事的地方**:
                          `deleteNodeConsequence` 里那句「无法撤销」不是套话,
                          是这一处与别处的全部区别。
                          ☞ 所以【不要】把别处的软删说明抄过来 —— 那会把一句实话
                            换成一句在这里为假的安慰。

                        ★【子步骤那条规矩【不】写进这句话里】★ 带子步骤的节点由
                          数据库按名拒(TASK_NODE_HAS_CHILDREN,绝不 CASCADE)。
                          把它写进确认框,等于描述一个「确认根本不适用」的情形 ——
                          那条拒绝会在按下之后按名出现,而它自己会说话。

                        ☞ 主语 = 这个步骤的标题(`n.title`),BTN-3b 交接时点的名。
                        ☞ 动作一个字没改:同一个 `run(() => removeNode(taskId, n.id))`。 */}
                    <ConfirmButton
                        subject={n.title}
                        title={labels.deleteNodeTitle}
                        body={labels.deleteNodeConsequence}
                        confirmLabel={labels.remove}
                        tier="destructive"
                        triggerVariant="destructive"
                        triggerSize="inline"
                        disabled={pending}
                        onConfirm={() => run(() => removeNode(taskId, n.id))}
                    >
                        {labels.remove}
                    </ConfirmButton>
                </span>
            </div>

            {kids(n.id).length > 0 ? <ul>{kids(n.id).map((k) => row(k, true))}</ul> : null}

            {addingUnder === n.id ? addForm(n.id) : null}
        </li>
    )

    const addForm = (parentId: string | null) => (
        <div className="my-2 flex flex-wrap items-center gap-2">
            <input
                className="rounded border px-2 py-1 text-sm"
                placeholder={labels.titlePlaceholder}
                value={draftTitle}
                onChange={(e) => setDraftTitle(e.target.value)}
            />
            <input
                type="date"
                className="rounded border px-1 py-1 text-sm"
                aria-label={labels.targetDate}
                value={draftDate}
                onChange={(e) => setDraftDate(e.target.value)}
            />
            <Button size="xs"
                disabled={pending || !draftTitle.trim()}
                onClick={() => { run(() => addNode(taskId, draftTitle, draftDate || null, parentId)); setDraftTitle(''); setDraftDate(''); setAddingUnder(undefined) }}>{labels.save}</Button>
            <Button variant="secondary" size="xs" onClick={() => setAddingUnder(undefined)}>{labels.cancel}</Button>
        </div>
    )

    return (
        <section className="mt-8 border-t pt-6">
            <div className="mb-3 flex items-center gap-3">
                <h2 className="text-xl font-bold">{labels.heading}</h2>
                {/* 【零步骤时这里一个字都没有】 */}
                {total > 0 ? <span className="text-sm text-gray-600">{doneCount}/{total}</span> : null}
            </div>

            {error ? (
                <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            ) : null}

            {total === 0 ? <p className="text-sm text-gray-500">{labels.empty}</p> : <ul>{tops.map((n) => row(n, false))}</ul>}

            {addingUnder === null ? (
                addForm(null)
            ) : (
                <Button variant="link" size="inline" className="mt-3 text-sm" onClick={() => { setAddingUnder(null); setDraftTitle(''); setDraftDate('') }}>
                    {labels.add}
                </Button>
            )}
        </section>
    )
}
