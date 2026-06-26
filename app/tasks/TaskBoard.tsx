'use client'

import { useState, useTransition } from 'react'
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
    tags: string[] | null
    task_type: string
}

const COLUMNS: { id: string; label: string }[] = [
    { id: 'todo', label: 'To Do' },
    { id: 'in_progress', label: 'In Progress' },
    { id: 'done', label: 'Done' },
]

function TaskCard({ task }: { task: Task }) {
    const { attributes, listeners, setNodeRef, transform, isDragging } =
        useDraggable({ id: task.id })

    const style = transform
        ? { transform: `translate3d(${transform.x}px, ${transform.y}px, 0)` }
        : undefined

    return (
        <div
            ref={setNodeRef}
            style={style}
            {...listeners}
            {...attributes}
            className={
                'cursor-grab touch-none rounded border border-gray-300 bg-white p-3 shadow-sm ' +
                (isDragging ? 'opacity-50' : '')
            }
        >
            <div className="text-sm font-medium text-gray-900">{task.title}</div>
            <div className="mt-1 font-mono text-xs text-gray-500">{task.code}</div>
        </div>
    )
}

function Column({
    id,
    label,
    tasks,
}: {
    id: string
    label: string
    tasks: Task[]
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
                    <TaskCard key={task.id} task={task} />
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
                    />
                ))}
            </div>
        </DndContext>
    )
}
