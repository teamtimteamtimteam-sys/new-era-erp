'use client'

import { useTransition } from 'react'
import { softDeleteMaterial } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'

export default function DeleteButton({
    id,
    name,
}: {
    id: string
    name: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    // CONFIRM-1:原来走的是原生确认框,消息键 materials.deleteConfirm。
    // 名字从【拼进句子】变成【对话框里自己的一格】—— 动作一个字没改。
    return (
        <ConfirmButton
            subject={name}
            title={t('materials.deleteConfirmTitle')}
            body={t('common.softDeleteNote')}
            details={
                <p className="text-sm font-medium text-[color:var(--brand-text)]">
                    {t('materials.deleteConsequence')}
                </p>
            }
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            triggerVariant="destructive" triggerSize="inline"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await softDeleteMaterial(id)
                    if (result?.error) {
                        showActionMessage({
                            subject: name,
                            headline: t('common.actionMessage.headline.notDeleted'),
                            body: result.error,
                            detail: result.detail,
                        })
                    }
                })
            }}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </ConfirmButton>
    )
}
