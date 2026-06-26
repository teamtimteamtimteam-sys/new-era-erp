'use client'

import { useEffect, useState, useTransition } from 'react'
import {
    DndContext,
    type DragEndEvent,
    PointerSensor,
    useSensor,
    useSensors,
    useDraggable,
    useDroppable,
} from '@dnd-kit/core'
import { updateTaskStatus } from './actions'

type Task = {
    id: string
    code: string
    title: string
    status: string
    priority: string
    due_date: string | null
    reminder_at: string | null
    tags: string[] | null
    task_type: string
}

const COLUMNS: { id: string; label: string }[] = [
    { id: 'todo', label: 'To Do' },
    { id: 'in_progress', label: 'In Progress' },
    { id: 'done', label: 'Done' },
]

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
    const cls = PRIORITY_STYLES[priority] ?? 'bg-gray-100 text-gray-600'
    return (
        <span
            className={`rounded px-1.5 py-0.5 text-[11px] font-medium capitalize ${cls}`}
        >
            {priority}
        </span>
    )
}

function TaskTypeBadge({ type }: { type: string }) {
    const isTeam = type === 'team'
    return (
        <span
            className={
                'shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide ' +
                (isTeam ? 'bg-blue-50 text-blue-600' : 'bg-gray-100 text-gray-500')
            }
        >
            {isTeam ? 'Team' : 'Personal'}
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

function TaskCard({ task, today }: { task: Task; today: string | null }) {
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
                    <TaskCard key={task.id} task={task} today={today} />
                ))}
                {tasks.length === 0 && (
                    <p className="rounded border border-dashed border-gray-300 p-4 text-center text-xs text-gray-400">
                        Drop tasks here
                    </p>
                )}
            </div>
        </div>
    )
}

export default function TaskBoard({ tasks: initialTasks }: { tasks: Task[] }) {
    const [tasks, setTasks] = useState<Task[]>(initialTasks)
    const [, startTransition] = useTransition()

    // 截止日期的"紧急上色"依赖当天日期,只在挂载后计算,避免 hydration 不一致
    const [today, setToday] = useState<string | null>(null)
    useEffect(() => setToday(localToday()), [])

    // 拖动 5px 才算开始拖拽,避免和点击冲突
    const sensors = useSensors(
        useSensor(PointerSensor, { activationConstraint: { distance: 5 } })
    )

    function handleDragEnd(event: DragEndEvent) {
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

    return (
        <DndContext id="task-board" sensors={sensors} onDragEnd={handleDragEnd}>
            <div className="flex gap-4 overflow-x-auto">
                {COLUMNS.map((col) => (
                    <Column
                        key={col.id}
                        id={col.id}
                        label={col.label}
                        tasks={tasks.filter((t) => t.status === col.id)}
                        today={today}
                    />
                ))}
            </div>
        </DndContext>
    )
}
