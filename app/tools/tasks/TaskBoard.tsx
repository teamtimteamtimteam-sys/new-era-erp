'use client'

import Link from 'next/link'
import { useCallback, useEffect, useRef, useState, useTransition } from 'react'
import {
    DndContext,
    type DragEndEvent,
    PointerSensor,
    useSensor,
    useSensors,
    useDraggable,
    useDroppable,
} from '@dnd-kit/core'
import { useTranslations } from '@/lib/i18n/client'
import { updateTaskStatus } from './actions'
import TaskModal from './TaskModal'
import { STATUS_VALUES, type Task } from './types'

const PRIORITY_STYLES: Record<string, string> = {
    high: 'bg-red-100 text-red-700',
    medium: 'bg-amber-100 text-amber-700',
    low: 'bg-gray-100 text-gray-600',
}

const MONTHS = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
]

// 本地当天 YYYY-MM-DD(只在客户端挂载后计算,避免 SSR 时区不一致)
function localToday() {
    const d = new Date()
    const p = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

// 用 UTC 锚点做纯日期差,结果只依赖日期字符串本身,确定可复现
function dayDiff(todayStr: string, dueStr: string) {
    const [ty, tm, td] = todayStr.split('-').map(Number)
    const [dy, dm, dd] = dueStr.split('-').map(Number)
    return Math.round(
        (Date.UTC(dy, dm - 1, dd) - Date.UTC(ty, tm - 1, td)) / 86_400_000
    )
}

// 把 'YYYY-MM-DD' 渲染成 'Jun 26'(纯字符串解析,无 locale / 时区)
function formatDue(dueStr: string) {
    const [, m, d] = dueStr.split('-').map(Number)
    return `${MONTHS[m - 1]} ${d}`
}

function PriorityBadge({ priority }: { priority: string }) {
    const t = useTranslations()
    const cls = PRIORITY_STYLES[priority] ?? 'bg-gray-100 text-gray-600'
    return (
        <span className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${cls}`}>
            {t('tasks.priority.' + priority)}
        </span>
    )
}

function TaskTypeBadge({ type }: { type: string }) {
    const t = useTranslations()
    const isTeam = type === 'team'
    return (
        <span
            className={
                'shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide ' +
                (isTeam ? 'bg-blue-50 text-blue-600' : 'bg-gray-100 text-gray-500')
            }
        >
            {t('tasks.type.' + type)}
        </span>
    )
}

function BellIcon() {
    return (
        <svg
            viewBox="0 0 20 20"
            fill="currentColor"
            className="h-3 w-3 text-gray-400"
            aria-hidden="true"
        >
            <path d="M10 2a5 5 0 0 0-5 5v2.6l-.9 2.7A1 1 0 0 0 5 14h10a1 1 0 0 0 .9-1.7L15 9.6V7a5 5 0 0 0-5-5Zm0 16a2.5 2.5 0 0 0 2.45-2h-4.9A2.5 2.5 0 0 0 10 18Z" />
        </svg>
    )
}

// today 在挂载前为 null:此时不上色,SSR 与首帧一致,挂载后再着色
function DueDate({ due, today }: { due: string; today: string | null }) {
    let tone = 'text-gray-500'
    if (today) {
        const diff = dayDiff(today, due)
        if (diff < 0) tone = 'text-red-600 font-medium'
        else if (diff <= 1) tone = 'text-amber-600 font-medium'
    }
    return <span className={'text-[11px] ' + tone}>{formatDue(due)}</span>
}

function TaskCard({
    task,
    today,
}: {
    task: Task
    today: string | null
}) {
    const t = useTranslations()
    const { attributes, listeners, setNodeRef, transform, isDragging } =
        useDraggable({ id: task.id })

    const style = transform
        ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` }
        : undefined

    const hasTags = !!task.tags && task.tags.length > 0
    const hasMeta = !!task.due_date || !!task.reminder_at

    return (
        <div
            ref={setNodeRef}
            style={style}
            {...listeners}
            {...attributes}
            className={
                'cursor-grab touch-none rounded-md border border-gray-200 bg-white p-3 shadow-sm hover:shadow ' +
                (isDragging ? 'opacity-50' : '')
            }
        >
            {/* TASK-1c-b:【整张卡片就是入口】。
                它是一个真正的 <a href>,不是一个 onClick —— 走查器读的是 DOM,
                只挂 onClick 的话 /tools/tasks/[id] 在标记里就【没有入口】了,
                而那正是 SAL-B6 那张新建客户页栽过的地方(动态路由不在断言范围内,
                所以检查会正当地报绿,人却点不到)。
                也【不带任何响应式显隐】—— FIX-1 的那条:CSS 藏起来的链接
                对走查器可达、对人不可见。 */}
            <Link href={`/tools/tasks/${task.id}`} className="block">
            {/* 标题 + 类型 */}
            <div className="flex items-start justify-between gap-2">
                <div className="text-sm font-medium leading-snug text-gray-900">
                    {task.title}
                </div>
                <TaskTypeBadge type={task.task_type} />
            </div>

            {/* 编号:更小更淡 */}
            <div className="mt-0.5 font-mono text-[10px] text-gray-400">
                {task.code}
            </div>

            {/* 优先级 + 截止日期 + 提醒 */}
            <div className="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1">
                <PriorityBadge priority={task.priority} />
                {hasMeta && (
                    <span className="flex items-center gap-1">
                        {task.reminder_at && <BellIcon />}
                        {task.due_date && (
                            <DueDate due={task.due_date} today={today} />
                        )}
                    </span>
                )}
            </div>

            {/* TASK-1b:派生值 —— 全部来自 task_board_rows,卡片不自己算。
                【零步骤时这里一个字都没有】:不是 0/0,也不是空进度条 ——
                0/0 读成"全没做"还是"全做完"取决于除法往哪边倒,两个都是编的。 */}
            {(task.node_count ?? 0) > 0 && (
                <div className="mt-1.5 text-[11px] text-gray-500">
                    {task.done_count}/{task.node_count}
                </div>
            )}
            {/* 【一句陈述,不是一个警告色】。没有截止日、或者没有带日期的未完成步骤时,
                视图给的是 null —— 那时这里什么都不说,而不是画一个"一切正常"的绿点。 */}
            {task.steps_overrun_due_date === true && (
                <div className="mt-1 text-[11px] text-amber-800">{t('tasks.card.stepsOverrun')}</div>
            )}

            {/* 标签 */}
            {hasTags && (
                <div className="mt-1.5 flex flex-wrap gap-1">
                    {task.tags!.map((tag) => (
                        <span
                            key={tag}
                            className="rounded-full bg-gray-100 px-2 py-0.5 text-[10px] text-gray-600"
                        >
                            {tag}
                        </span>
                    ))}
                </div>
            )}
            </Link>
        </div>
    )
}

function Column({
    id,
    label,
    tasks,
    today,
}: {
    id: string
    label: string
    tasks: Task[]
    today: string | null
}) {
    const t = useTranslations()
    const { setNodeRef, isOver } = useDroppable({ id })

    return (
        <div
            ref={setNodeRef}
            className={
                'flex w-80 flex-col rounded-lg border p-3 ' +
                (isOver ? 'border-blue-400 bg-blue-50' : 'border-gray-200 bg-gray-50')
            }
        >
            <h2 className="mb-3 text-sm font-semibold text-gray-700">
                {label} <span className="text-gray-400">({tasks.length})</span>
            </h2>
            <div className="flex min-h-16 flex-col gap-2">
                {tasks.map((task) => (
                    <TaskCard
                        key={task.id}
                        task={task}
                        today={today}
                    />
                ))}
                {tasks.length === 0 && (
                    <p className="rounded border border-dashed border-gray-300 p-4 text-center text-xs text-gray-400">
                        {t('tasks.dropPlaceholder')}
                    </p>
                )}
            </div>
        </div>
    )
}

// TASK-1c-b:弹窗只剩【新建】。改任务在 /tools/tasks/[id] —— 一个事实一个入口。
type ModalState = { mode: 'create' } | null

export default function TaskBoard({ tasks: initialTasks }: { tasks: Task[] }) {
    const t = useTranslations()
    const [tasks, setTasks] = useState<Task[]>(initialTasks)
    const [, startTransition] = useTransition()
    const [modal, setModal] = useState<ModalState>(null)

    // 截止日期的"紧急上色"依赖当天日期,只在挂载后计算,避免 hydration 不一致
    const [today, setToday] = useState<string | null>(null)
    useEffect(() => setToday(localToday()), [])

    // 区分"点击编辑"和"拖拽":拖拽真正发生时置 true,吞掉随后的 click
    const wasDraggingRef = useRef(false)

    // 拖动 5px 才算开始拖拽,避免和点击冲突
    const sensors = useSensors(
        useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
    )

    function handleDragStart() {
        wasDraggingRef.current = true
    }

    function handleDragCancel() {
        // 没有产生 click,直接清掉标记
        wasDraggingRef.current = false
    }

    function handleDragEnd(event: DragEndEvent) {
        // 拖拽后浏览器会补发一次 click,放到下个事件循环再清标记,确保那次 click 被吞掉
        setTimeout(() => {
            wasDraggingRef.current = false
        }, 0)

        const { active, over } = event
        if (!over) return

        const taskId = String(active.id)
        const newStatus = String(over.id)
        const task = tasks.find((t) => t.id === taskId)
        if (!task || task.status === newStatus) return

        // 乐观更新:先移动卡片
        const prevStatus = task.status
        setTasks((prev) =>
            prev.map((t) => (t.id === taskId ? { ...t, status: newStatus } : t))
        )

        startTransition(async () => {
            const result = await updateTaskStatus(taskId, newStatus)
            if (result?.error) {
                // 失败回滚
                setTasks((prev) =>
                    prev.map((t) =>
                        t.id === taskId ? { ...t, status: prevStatus } : t
                    )
                )
                alert(result.error)
            }
        })
    }

    const closeModal = useCallback(() => setModal(null), [])

    // 新建/编辑成功:存在则替换,不存在则插到最前(列表按 created_at 倒序)
    const handleSaved = useCallback((saved: Task) => {
        setTasks((prev) =>
            prev.some((t) => t.id === saved.id)
                ? prev.map((t) => (t.id === saved.id ? saved : t))
                : [saved, ...prev]
        )
    }, [])


    return (
        <>
            <div className="mb-4">
                <button
                    onClick={() => setModal({ mode: 'create' })}
                    className="rounded bg-blue-600 px-4 py-2 text-white hover:bg-blue-700"
                >
                    {t('tasks.addButton')}
                </button>
            </div>

            <DndContext
                id="task-board"
                sensors={sensors}
                onDragStart={handleDragStart}
                onDragCancel={handleDragCancel}
                onDragEnd={handleDragEnd}
            >
                <div className="flex gap-4 overflow-x-auto">
                    {STATUS_VALUES.map((status) => (
                        <Column
                            key={status}
                            id={status}
                            label={t('tasks.status.' + status)}
                            tasks={tasks.filter((task) => task.status === status)}
                            today={today}
                        />
                    ))}
                </div>
            </DndContext>

            {modal && (
                <TaskModal
                    mode="create"
                    onClose={closeModal}
                    onSaved={handleSaved}
                />
            )}
        </>
    )
}
