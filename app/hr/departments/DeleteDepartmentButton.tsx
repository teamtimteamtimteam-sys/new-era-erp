'use client'

// 部门软删按钮(window.confirm)。部门还有在册员工时,动作会返回一句人话,
// 这里原样显示 —— 不让外键报错跑到用户面前。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { deleteDepartment } from './actions'

export default function DeleteDepartmentButton({ id, name }: { id: string; name: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onDelete() {
        if (!window.confirm(t('hr.deleteDepartmentConfirm', { 0: name }))) return
        setError('')
        startTransition(async () => {
            const res = await deleteDepartment(id)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <>
            <button
                type="button"
                onClick={onDelete}
                disabled={isPending}
                className="text-red-600 hover:underline disabled:text-gray-400"
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </button>
            {error && <p className="text-xs text-red-600 mt-1">{error}</p>}
        </>
    )
}
