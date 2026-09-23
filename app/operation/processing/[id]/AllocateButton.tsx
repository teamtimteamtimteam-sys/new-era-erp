'use client'

import { useState, useTransition } from 'react'
import { runAllocation } from './allocationActions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

// ★ ROLE-1(Tim 的矩阵,2026-09-23):加工成本分摊改归财务 —— allocate_processing_costs 的门
//   从 module.processing.edit 换成 module.finance.edit(分摊过的是资本化分录)。
//   此前这颗按钮【没有任何权限判断】,靠服务端拒;按 DBLOCK-1,它现在对拿不到的人
//   【看得见、按不动、说出要哪个码】。
export default function AllocateButton({ runId, canAllocate }: { runId: string; canAllocate: boolean }) {
    const t = useTranslations()
    const [error, setError] = useState<string | null>(null)
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        setError(null)
        startTransition(async () => {
            const result = await runAllocation(runId)
            if (result?.error) setError(result.error)
        })
    }

    return (
        <PermissionGate code="module.finance.edit" allowed={canAllocate}>
            <Button
                type="button"
                onClick={handleClick}
                disabled={isPending}
                variant="default" size="default"
            >
                {isPending ? t('processing.allocation.running') : t('processing.allocation.button')}
            </Button>
            {error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mt-3">
                    {error}
                </div>
            )}
        </PermissionGate>
    )
}
