'use client'

// 关账按钮:确认对话框(主语是期末日)后调 closePeriod,失败 alert
// (端口自 journal ReverseButton);成功由 revalidate 刷新本页。
import { useTransition } from 'react'
import { closePeriod } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'

export default function CloseButton({ periodEnd }: { periodEnd: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doClose() {
        startTransition(async () => {
            const result = await closePeriod(periodEnd)
            if (result?.error) {
                showActionMessage({
                    subject: periodEnd,
                    headline: t('common.actionMessage.headline.notClosed'),
                    body: result.error,
                    detail: result.detail,
                })
            }
        })
    }

    return (
        <ConfirmButton
            subject={periodEnd}
            title={t('finance.closeConfirm', { date: periodEnd })}
            confirmLabel={t('finance.closeButton')}
            tier="destructive"
            triggerVariant="default"
            disabled={isPending}
            onConfirm={doClose}
        >
            {isPending ? t('common.saving') : t('finance.closeButton')}
        </ConfirmButton>
    )
}
