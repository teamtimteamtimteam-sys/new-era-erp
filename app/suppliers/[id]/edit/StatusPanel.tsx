'use client'

// CONFIRM-1:重要的状态迁移原来问的是原生确认框,而【它不说这是哪一家】——
//   一张供应商编辑页上只有一家,可确认框本身答不出这件事,冒烟也点不到它。
//   ★ 只有 DESTRUCTIVE_TRANSITIONS 里那几档要确认,其余照旧直接执行 ——
//     这条判据一个字没改,只是"要确认"的那一支换了实现。
//   ★ 那条消息里的 `\n\n` / `\n` 原来靠灰盒子换行;现在它们是 details 里
//     真正的几行 <p>。**一个字都没有改写** —— 只是不再被压成一段。
import { useTransition } from 'react'
import { changeSupplierStatus } from './statusActions'
import { ALLOWED_TRANSITIONS, DESTRUCTIVE_TRANSITIONS } from './statusMachine'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import type { Database } from '@/lib/database.types'

type SupplierStatus = Database['public']['Enums']['supplier_status']

export default function StatusPanel({
    id,
    subject,
    currentStatus,
}: {
    id: string
    /** CONFIRM-1:这一次改的是【哪一家】—— 供应商代号,抬头里就印着它。 */
    subject: string
    currentStatus: SupplierStatus
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    const allowedTargets = ALLOWED_TRANSITIONS[currentStatus] ?? []

    function handleClick(targetStatus: SupplierStatus) {
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
                            const cls = isDestructive
                                ? 'border border-red-300 text-red-700 bg-white px-3 py-1.5 rounded text-sm hover:bg-red-50 disabled:opacity-50'
                                : 'border border-blue-300 text-blue-700 bg-white px-3 py-1.5 rounded text-sm hover:bg-blue-50 disabled:opacity-50'
                            const face = (
                                <>
                                    {isPending
                                        ? t('suppliers.statusPanel.processing')
                                        : t('suppliers.statusAction.' + target)}
                                    <span className="ml-1 text-xs text-gray-400">
                                        → {t('suppliers.status.' + target)}
                                    </span>
                                </>
                            )
                            if (!isDestructive) {
                                return (
                                    <button key={target} type="button" disabled={isPending}
                                            onClick={() => handleClick(target)} className={cls}>
                                        {face}
                                    </button>
                                )
                            }
                            // 那条消息原样取出来,再按它自己的换行拆成几行 —— 词不动,只是不再被压平。
                            const blocks = t('suppliers.statusPanel.changeConfirm', {
                                action: t('suppliers.statusAction.' + target),
                                current: t('suppliers.status.' + currentStatus),
                                next: t('suppliers.status.' + target),
                            }).split('\n\n')
                            return (
                                <ConfirmButton
                                    key={target}
                                    subject={subject}
                                    title={blocks[0]}
                                    details={
                                        blocks.length > 1 ? (
                                            <div className="space-y-1 text-sm text-muted-foreground">
                                                {blocks.slice(1).join('\n').split('\n').map((line, i) => (
                                                    <p key={i}>{line}</p>
                                                ))}
                                            </div>
                                        ) : undefined
                                    }
                                    confirmLabel={t('suppliers.statusAction.' + target)}
                                    tier="destructive"
                                    disabled={isPending}
                                    onConfirm={() => handleClick(target)}
                                    className={cls}
                                >
                                    {face}
                                </ConfirmButton>
                            )
                        })}
                    </div>
                </div>
            )}
        </div>
    )
}
