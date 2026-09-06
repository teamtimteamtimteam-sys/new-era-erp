'use client'

import { useTransition } from 'react'
import { softDeleteSupplier } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function DeleteButton({
    id,
    legalName,
}: {
    id: string
    legalName: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    // CONFIRM-1:原来走的是原生确认框,消息键 suppliers.deleteConfirm。
    // 名字从【拼进句子】变成【对话框里自己的一格】—— 动作一个字没改。
    return (
        <ConfirmButton
            subject={legalName}
            title={t('suppliers.deleteConfirmTitle')}
            body={t('common.softDeleteNote')}
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            className="text-red-600 hover:underline disabled:text-gray-400"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await softDeleteSupplier(id)
                    if (result?.error) {
                        alert(result.error)
                    }
                })
            }}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </ConfirmButton>
    )
}
