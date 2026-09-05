'use client'

// 冲销按钮(danger outline):window.confirm 后调 reverseEntry,失败 alert
// (端口自 inbound/DeleteButton);成功由 action 重定向到冲销单详情。
import { useTransition } from 'react'
import { reverseEntry } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function ReverseButton({ entryId }: { entryId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('finance.reverseConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await reverseEntry(entryId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <Button variant="reversal" size="sm"
            onClick={handleClick}
            disabled={isPending}
        >
            {isPending ? t('common.saving') : t('finance.reverse')}
        </Button>
    )
}
