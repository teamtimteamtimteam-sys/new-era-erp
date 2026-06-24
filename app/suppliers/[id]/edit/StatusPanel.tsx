'use client'

import { useTransition } from 'react'
import { changeSupplierStatus } from './statusActions'
import {
    STATUS_LABELS,
    ALLOWED_TRANSITIONS,
    TRANSITION_LABELS,
    DESTRUCTIVE_TRANSITIONS,
} from './statusMachine'
import type { Database } from '@/lib/database.types'

type SupplierStatus = Database['public']['Enums']['supplier_status']

export default function StatusPanel({
    id,
    currentStatus,
}: {
    id: string
    currentStatus: SupplierStatus
}) {
    const [isPending, startTransition] = useTransition()

    const allowedTargets = ALLOWED_TRANSITIONS[currentStatus] ?? []

    function handleClick(targetStatus: SupplierStatus) {
        const targetLabel = TRANSITION_LABELS[targetStatus] ?? targetStatus
        const currentLabel = STATUS_LABELS[currentStatus] ?? currentStatus

        // 重要操作要二次确认
        if (DESTRUCTIVE_TRANSITIONS.has(targetStatus)) {
            const ok = window.confirm(
                `确定要执行「${targetLabel}」吗?\n\n当前状态:${currentLabel}\n变更后:${STATUS_LABELS[targetStatus]}\n\n该操作不影响合规记录,但可能影响下单流程。`
            )
            if (!ok) return
        }

        startTransition(async () => {
            const result = await changeSupplierStatus(id, targetStatus)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <div className="border border-gray-300 rounded p-4 mb-6 bg-gray-50">
            <div className="flex items-center justify-between mb-3">
                <div>
                    <div className="text-xs text-gray-500 mb-1">当前状态</div>
                    <div className="text-lg font-medium">
                        {STATUS_LABELS[currentStatus] ?? currentStatus}
                        <span className="ml-2 text-xs text-gray-400 font-mono">
                            ({currentStatus})
                        </span>
                    </div>
                </div>
            </div>

            {allowedTargets.length === 0 ? (
                <p className="text-sm text-gray-500">当前状态没有可执行的操作。</p>
            ) : (
                <div>
                    <div className="text-xs text-gray-500 mb-2">可执行的状态变更:</div>
                    <div className="flex flex-wrap gap-2">
                        {allowedTargets.map((target) => {
                            const isDestructive = DESTRUCTIVE_TRANSITIONS.has(target)
                            return (
                                <button
                                    key={target}
                                    type="button"
                                    disabled={isPending}
                                    onClick={() => handleClick(target)}
                                    className={
                                        isDestructive
                                            ? 'border border-red-300 text-red-700 bg-white px-3 py-1.5 rounded text-sm hover:bg-red-50 disabled:opacity-50'
                                            : 'border border-blue-300 text-blue-700 bg-white px-3 py-1.5 rounded text-sm hover:bg-blue-50 disabled:opacity-50'
                                    }
                                >
                                    {isPending ? '处理中...' : TRANSITION_LABELS[target] ?? target}
                                    <span className="ml-1 text-xs text-gray-400">→ {STATUS_LABELS[target]}</span>
                                </button>
                            )
                        })}
                    </div>
                </div>
            )}
        </div>
    )
}