'use client'

import { useTransition } from 'react'
import { changeSupplierStatus } from './statusActions'
import { ALLOWED_TRANSITIONS, DESTRUCTIVE_TRANSITIONS } from './statusMachine'
import { useTranslations } from '@/lib/i18n/client'
import type { Database } from '@/lib/database.types'

type SupplierStatus = Database['public']['Enums']['supplier_status']

export default function StatusPanel({
    id,
    currentStatus,
}: {
    id: string
    currentStatus: SupplierStatus
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    const allowedTargets = ALLOWED_TRANSITIONS[currentStatus] ?? []

    function handleClick(targetStatus: SupplierStatus) {
        // 重要操作要二次确认
        if (DESTRUCTIVE_TRANSITIONS.has(targetStatus)) {
            const ok = window.confirm(
                t('suppliers.statusPanel.changeConfirm', {
                    action: t('suppliers.statusAction.' + targetStatus),
                    current: t('suppliers.status.' + currentStatus),
                    next: t('suppliers.status.' + targetStatus),
                })
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
                    <div className="text-xs text-gray-500 mb-1">
                        {t('suppliers.statusPanel.current')}
                    </div>
                    <div className="text-lg font-medium">
                        {t('suppliers.status.' + currentStatus)}
                        <span className="ml-2 text-xs text-gray-400 font-mono">
                            ({currentStatus})
                        </span>
                    </div>
                </div>
            </div>

            {allowedTargets.length === 0 ? (
                <p className="text-sm text-gray-500">
                    {t('suppliers.statusPanel.noActions')}
                </p>
            ) : (
                <div>
                    <div className="text-xs text-gray-500 mb-2">
                        {t('suppliers.statusPanel.availableChanges')}
                    </div>
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
                                    {isPending
                                        ? t('suppliers.statusPanel.processing')
                                        : t('suppliers.statusAction.' + target)}
                                    <span className="ml-1 text-xs text-gray-400">
                                        → {t('suppliers.status.' + target)}
                                    </span>
                                </button>
                            )
                        })}
                    </div>
                </div>
            )}
        </div>
    )
}
