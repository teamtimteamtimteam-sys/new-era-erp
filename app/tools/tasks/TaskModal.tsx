'use client'

import { useEffect, useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { createTask } from './actions'
import {
    type Task,
    type TaskInput,
    STATUS_VALUES,
    PRIORITY_VALUES,
    TASK_TYPE_VALUES,
} from './types'
import { Button } from '@/app/components/ui/button'

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

// TASK-1c-b:【只建不改】。改任务(含软删)在 /tools/tasks/[id]。
// 一个事实一个入口 —— 这不是省事,是把"两扇门规矩各自演化"那一类毛病
// 从根上拆掉(1c-a 为账号关联那一处记过同样的账)。
// 顺带:类型下拉也随之消失,所以原计划里"把它改成只读"那一条自然作废。
export default function TaskModal({
    onClose,
    onSaved,
}: {
    mode?: 'create'
    onClose: () => void
    onSaved: (task: Task) => void
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
            const res = await createTask(input)

            if ('error' in res) {
                setError(res.error)
                return
            }
            onSaved(res.task)
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
                    {t('tasks.newTitle')}
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
                            defaultValue=""
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
                            defaultValue=""
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
                                defaultValue="todo"
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
                                defaultValue="medium"
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
                                defaultValue="personal"
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
                                defaultValue=""
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
                                defaultValue=""
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
                            defaultValue=""
                            className={inputCls}
                            placeholder={t('tasks.form.tagsPlaceholder')}
                        />
                        <p className="mt-1 text-xs text-gray-500">
                            {t('tasks.form.tagsHint')}
                        </p>
                    </div>

                    {/* 操作按钮 */}
                    <div className="flex items-center justify-between pt-2">
                        {/* 删除【不在这里】—— 它随表头一起搬到了 /tools/tasks/[id]。 */}
                        <span />

                        <div className="flex gap-3">
                            <Button variant="secondary"
                                type="button"
                                onClick={onClose}>
                                {t('common.cancel')}
                            </Button>
                            <Button
                                type="submit"
                                disabled={isPending}>
                                {isPending ? t('common.saving') : t('common.save')}
                            </Button>
                        </div>
                    </div>
                </form>
            </div>
        </div>
    )
}
