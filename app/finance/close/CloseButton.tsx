'use client'

// 关账按钮:window.confirm(带期末日)后调 closePeriod,失败 alert
// (端口自 journal ReverseButton);成功由 revalidate 刷新本页。
import { useTransition } from 'react'
import { closePeriod } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function CloseButton({ periodEnd }: { periodEnd: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('finance.closeConfirm', { date: periodEnd }))
        if (!confirmed) return

        startTransition(async () => {
            const result = await closePeriod(periodEnd)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <Button
            onClick={handleClick}
            disabled={isPending}
        >
            {isPending ? t('common.saving') : t('finance.closeButton')}
        </Button>
    )
}
