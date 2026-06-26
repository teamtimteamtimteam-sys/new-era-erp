'use client'

import { useEffect, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { createTask, updateTask, deleteTask } from './actions'
import {
    type Task,
    type TaskInput,
    STATUS_VALUES,
    PRIORITY_VALUES,
    TASK_TYPE_VALUES,
} from './types'

// 逗号分隔字符串 -> 去重去空的标签数组
function parseTags(raw: string): string[] {
    const seen = new Set<string>()
    for (const part of raw.split(',')) {
        const tag = part.trim()
        if (tag) seen.add(tag)
    }
    return [...seen]
}

// ISO 时间戳 -> datetime-local 需要的本地 'YYYY-MM-DDTHH:mm'
// (本组件只在用户打开弹窗时挂载,不参与 SSR,故可安全使用本地时区)
function toLocalDatetime(iso: string | null): string {
    if (!iso) return ''
    const d = new Date(iso)
    const p = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`
}

const inputCls = 'w-full border border-gray-300 px-3 py-2 rounded'
const labelCls = 'block text-sm font-medium mb-1'

export default function TaskModal({
    mode,
    task,
    onClose,
    onSaved,
    onDeleted,
}: {
    mode: 'create' | 'edit'
    task: Task | null
    onClose: () => void
    onSaved: (task: Task) => void
    onDeleted: (id: string) => void
}) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    // Esc 关闭
    useEffect(() => {
        function onKey(e: KeyboardEvent) {
            if (e.key === 'Escape') onClose()
        }
        window.addEventListener('keydown', onKey)
        return () => window.removeEventListener('keydown', onKey)
    }, [onClose])

    function handleSubmit(e: React.FormEvent<HTMLFormElement>) {
        e.preventDefault()
        const fd = new FormData(e.currentTarget)
        const reminderLocal = (fd.get('reminder_at') as string) || ''

        const input: TaskInput = {
            title: ((fd.get('title') as string) ?? '').trim(),
            description: ((fd.get('description') as string) ?? '').trim() || null,
            status: fd.get('status') as string,
            priority: fd.get('priority') as string,
            task_type: fd.get('task_type') as string,
            due_date: (fd.get('due_date') as string) || null,
            reminder_at: reminderLocal
                ? new Date(reminderLocal).toISOString()
                : null,
            tags: parseTags((fd.get('tags') as string) ?? ''),
        }

        setError(null)
        startTransition(async () => {
            const res =
                mode === 'create'
                    ? await createTask(input)
                    : await updateTask(task!.id, input)

            if ('error' in res) {
                setError(res.error)
                return
            }
            onSaved(res.task)
            onClose()
        })
    }

    function handleDelete() {
        if (!task) return
        const ok = window.confirm(
            t('tasks.deleteConfirm', { title: task.title })
        )
        if (!ok) return

        setError(null)
        startTransition(async () => {
            const res = await deleteTask(task.id)
            if ('error' in res) {
                setError(res.error)
                return
            }
            onDeleted(task.id)
            onClose()
        })
    }

    return (
        <div
            className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center"
            onClick={onClose}
        >
            <div
                className="w-full max-w-lg rounded-lg bg-white p-6 shadow-xl"
                onClick={(e) => e.stopPropagation()}
            >
                <h2 className="mb-4 text-lg font-bold">
                    {mode === 'create'
                        ? t('tasks.newTitle')
                        : t('tasks.editTitle')}
                </h2>

                {error && (
                    <div className="mb-4 rounded border border-red-400 bg-red-100 px-4 py-2 text-sm text-red-700">
                        {error}
                    </div>
                )}

                <form onSubmit={handleSubmit} className="space-y-4">
                    {/* 标题(必填) */}
                    <div>
                        <label className={labelCls}>
                            {t('tasks.form.title')}{' '}
                            <span className="text-red-600">*</span>
                        </label>
                        <input
                            type="text"
                            name="title"
                            required
                            autoFocus
                            defaultValue={task?.title ?? ''}
                            className={inputCls}
                            placeholder={t('tasks.form.titlePlaceholder')}
                        />
                    </div>

                    {/* 描述 */}
                    <div>
                        <label className={labelCls}>
                            {t('tasks.form.description')}
                        </label>
                        <textarea
                            name="description"
                            rows={3}
                            defaultValue={task?.description ?? ''}
                            className={inputCls}
                        />
                    </div>

                    {/* 状态 / 优先级 / 类型 */}
                    <div className="grid grid-cols-3 gap-3">
                        <div>
                            <label className={labelCls}>
                                {t('tasks.form.status')}
                            </label>
                            <select
                                name="status"
                                defaultValue={task?.status ?? 'todo'}
                                className={inputCls}
                            >
                                {STATUS_VALUES.map((v) => (
                                    <option key={v} value={v}>
                                        {t('tasks.status.' + v)}
                                    </option>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className={labelCls}>
                                {t('tasks.form.priority')}
                            </label>
                            <select
                                name="priority"
                                defaultValue={task?.priority ?? 'medium'}
                                className={inputCls}
                            >
                                {PRIORITY_VALUES.map((v) => (
                                    <option key={v} value={v}>
                                        {t('tasks.priority.' + v)}
                                    </option>
                                ))}
                            </select>
                        </div>
                        <div>
                            <label className={labelCls}>
                                {t('tasks.form.type')}
                            </label>
                            <select
                                name="task_type"
                                defaultValue={task?.task_type ?? 'personal'}
                                className={inputCls}
                            >
                                {TASK_TYPE_VALUES.map((v) => (
                                    <option key={v} value={v}>
                                        {t('tasks.type.' + v)}
                                    </option>
                                ))}
                            </select>
                        </div>
                    </div>

                    {/* 截止日期 / 提醒时间 */}
                    <div className="grid grid-cols-2 gap-3">
                        <div>
                            <label className={labelCls}>
                                {t('tasks.form.dueDate')}
                            </label>
                            <input
                                type="date"
                                name="due_date"
                                defaultValue={task?.due_date ?? ''}
                                className={inputCls}
                            />
                        </div>
                        <div>
                            <label className={labelCls}>
                                {t('tasks.form.reminder')}
                            </label>
                            <input
                                type="datetime-local"
                                name="reminder_at"
                                defaultValue={toLocalDatetime(task?.reminder_at ?? null)}
                                className={inputCls}
                            />
                        </div>
                    </div>

                    {/* 标签(逗号分隔) */}
                    <div>
                        <label className={labelCls}>{t('tasks.form.tags')}</label>
                        <input
                            type="text"
                            name="tags"
                            defaultValue={task?.tags?.join(', ') ?? ''}
                            className={inputCls}
                            placeholder={t('tasks.form.tagsPlaceholder')}
                        />
                        <p className="mt-1 text-xs text-gray-500">
                            {t('tasks.form.tagsHint')}
                        </p>
                    </div>

                    {/* 操作按钮 */}
                    <div className="flex items-center justify-between pt-2">
                        {/* 删除只在编辑态出现 */}
                        {mode === 'edit' ? (
                            <button
                                type="button"
                                onClick={handleDelete}
                                disabled={isPending}
                                className="text-sm text-red-600 hover:underline disabled:text-gray-400"
                            >
                                {t('common.delete')}
                            </button>
                        ) : (
                            <span />
                        )}

                        <div className="flex gap-3">
                            <button
                                type="button"
                                onClick={onClose}
                                className="rounded border border-gray-300 px-4 py-2 hover:bg-gray-50"
                            >
                                {t('common.cancel')}
                            </button>
                            <button
                                type="submit"
                                disabled={isPending}
                                className="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700 disabled:bg-gray-400"
                            >
                                {isPending ? t('common.saving') : t('common.save')}
                            </button>
                        </div>
                    </div>
                </form>
            </div>
        </div>
    )
}
