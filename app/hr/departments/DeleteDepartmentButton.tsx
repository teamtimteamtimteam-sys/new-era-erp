'use client'

// 部门软删按钮。部门还有在册员工时,动作会返回一句人话,
// 这里原样显示 —— 不让外键报错跑到用户面前。
// CONFIRM-1:确认从原生确认框换成 <ConfirmButton> —— 名字进了对话框自己那一格。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { deleteDepartment } from './actions'

export default function DeleteDepartmentButton({ id, name }: { id: string; name: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <>
            <ConfirmButton
                subject={name}
                title={t('hr.deleteDepartmentConfirmTitle')}
                confirmLabel={t('common.delete')}
                tier="destructive"
                disabled={isPending}
                className="text-red-600 hover:underline disabled:text-gray-400"
                onConfirm={() => {
                    setError('')
                    startTransition(async () => {
                        const res = await deleteDepartment(id)
                        if (res.error) setError(res.error)
                        else router.refresh()
                    })
                }}
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </ConfirmButton>
            {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
        </>
    )
}
