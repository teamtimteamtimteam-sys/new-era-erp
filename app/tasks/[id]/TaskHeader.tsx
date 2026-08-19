'use client'

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { updateTaskHeader, softDeleteTask } from './actions'
import { STATUS_VALUES, PRIORITY_VALUES } from '../types'

// app/tasks/[id]/TaskHeader.tsx
// TASK-1c-b:表头编辑。弹窗退休成【只建不改】之后,这七个字段搬到了这里。
//
// 【为什么不是把弹窗留着改表头】:那会留下两扇门 —— 而两扇门写同一个事实、
// 规矩却各自演化,正是 1c-a 记进 known-issues.md 的那一类毛病。
// 一个事实一个入口,所以弹窗只剩"新建"。
//
// 【这里【没有】类型下拉】。personal ↔ team 只剩两扇具名的门,在参与者面板上;
// 表头再收一次 task_type 等于把刚拆掉的第二扇门装回来。原计划里"把弹窗的
// 类型下拉改成只读"那一条因此作废 —— 没有那个下拉可以守了。

export type HeaderLabels = {
    edit: string; save: string; cancel: string; del: string; confirmDelete: string
    title: string; description: string; status: string; priority: string
    dueDate: string; reminderAt: string; tags: string; tagsHint: string
    // 【查好的表,不是函数】。函数不能跨 RSC 边界序列化 ——
    // 服务端组件把它塞进 props 会当场 500(Functions cannot be passed directly
    // to Client Components)。标签在服务端查好,传字典过来。
    statusLabels: Record<string, string>
    priorityLabels: Record<string, string>
}

function parseTags(raw: string): string[] {
    const seen = new Set<string>()
    for (const part of raw.split(',')) {
        const tag = part.trim()
        if (tag) seen.add(tag)
    }
    return [...seen]
}

// datetime-local 要的是本地时间字符串,而库里存的是 ISO(UTC)。
function toLocalInput(iso: string | null): string {
    if (!iso) return ''
    const d = new Date(iso)
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

export default function TaskHeader({
    task,
    labels,
}: {
    task: {
        id: string
        title: string
        description: string | null
        status: string
        priority: string
        due_date: string | null
        reminder_at: string | null
        tags: string[] | null
    }
    labels: HeaderLabels
}) {
    const [open, setOpen] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [confirming, setConfirming] = useState(false)
    const [pending, start] = useTransition()
    const router = useRouter()

    const field = 'w-full rounded border border-gray-300 px-2 py-1 text-sm'
    const label = 'block text-xs font-medium text-gray-600 mb-1'

    function onSubmit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        const local = (fd.get('reminder_at') as string) || ''
        setError(null)
        start(async () => {
            const res = await updateTaskHeader(task.id, {
                title: ((fd.get('title') as string) ?? '').trim(),
                description: ((fd.get('description') as string) ?? '').trim() || null,
                status: fd.get('status') as string,
                priority: fd.get('priority') as string,
                due_date: (fd.get('due_date') as string) || null,
                reminder_at: local ? new Date(local).toISOString() : null,
                tags: parseTags((fd.get('tags') as string) ?? ''),
            })
            if ('error' in res) setError(res.error)
            else setOpen(false)
        })
    }

    if (!open) {
        return (
            <div className="mb-4">
                {error ? (
                    <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
                ) : null}
                <button
                    className="text-sm text-blue-700 hover:underline"
                    onClick={() => { setError(null); setOpen(true) }}
                >
                    {labels.edit}
                </button>
            </div>
        )
    }

    return (
        <form onSubmit={onSubmit} className="mb-6 rounded border border-gray-200 bg-gray-50 p-4">
            {error ? (
                <div className="mb-3 rounded border border-red-400 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            ) : null}

            <div className="mb-3">
                <label className={label}>{labels.title}</label>
                <input name="title" required defaultValue={task.title} className={field} />
            </div>

            <div className="mb-3">
                <label className={label}>{labels.description}</label>
                <textarea name="description" rows={3} defaultValue={task.description ?? ''} className={field} />
            </div>

            <div className="mb-3 flex flex-wrap gap-3">
                <div className="min-w-[8rem] flex-1">
                    <label className={label}>{labels.status}</label>
                    <select name="status" defaultValue={task.status} className={field}>
                        {STATUS_VALUES.map((v) => (
                            <option key={v} value={v}>{labels.statusLabels[v] ?? v}</option>
                        ))}
                    </select>
                </div>
                <div className="min-w-[8rem] flex-1">
                    <label className={label}>{labels.priority}</label>
                    <select name="priority" defaultValue={task.priority} className={field}>
                        {PRIORITY_VALUES.map((v) => (
                            <option key={v} value={v}>{labels.priorityLabels[v] ?? v}</option>
                        ))}
                    </select>
                </div>
                <div className="min-w-[9rem] flex-1">
                    <label className={label}>{labels.dueDate}</label>
                    <input type="date" name="due_date" defaultValue={task.due_date ?? ''} className={field} />
                </div>
                <div className="min-w-[12rem] flex-1">
                    <label className={label}>{labels.reminderAt}</label>
                    <input type="datetime-local" name="reminder_at" defaultValue={toLocalInput(task.reminder_at)} className={field} />
                </div>
            </div>

            <div className="mb-4">
                <label className={label}>{labels.tags}</label>
                <input name="tags" defaultValue={(task.tags ?? []).join(', ')} className={field} />
                <p className="mt-1 text-xs text-gray-500">{labels.tagsHint}</p>
            </div>

            <div className="flex items-center gap-2">
                <button
                    type="submit"
                    disabled={pending}
                    className="rounded bg-blue-600 px-3 py-1 text-sm text-white disabled:opacity-50"
                >{labels.save}</button>
                <button
                    type="button"
                    disabled={pending}
                    onClick={() => { setOpen(false); setError(null); setConfirming(false) }}
                    className="rounded border px-3 py-1 text-sm"
                >{labels.cancel}</button>

                <span className="flex-1" />

                {/* 删除是软删 —— 硬删由 trg_tasks_no_hard_delete 按名拒绝。
                    确认走的是【第二次点击】,不是 window.confirm:后者在测试里点不到。 */}
                {confirming ? (
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() =>
                            start(async () => {
                                const res = await softDeleteTask(task.id)
                                if ('error' in res) { setError(res.error); setConfirming(false) }
                                else router.push('/tasks')
                            })
                        }
                        className="rounded bg-red-600 px-3 py-1 text-sm text-white disabled:opacity-50"
                    >{labels.confirmDelete}</button>
                ) : (
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() => setConfirming(true)}
                        className="text-sm text-red-700 hover:underline"
                    >{labels.del}</button>
                )}
            </div>
        </form>
    )
}
