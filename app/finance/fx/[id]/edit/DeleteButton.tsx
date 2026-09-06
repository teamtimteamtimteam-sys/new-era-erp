'use client'

import { useTransition } from 'react'
import { softDeleteFxRate } from './actions'
import { Button } from '@/app/components/ui/button'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id }: { id: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        // FX-RATES-1:撤销要理由。**不给默认值、不接受空白** —— 一条无声消失的
        // 牌价,日后没有人解释得了。取消(prompt 返回 null)就什么都不做。
        const reason = window.prompt(t('finance.fxPage.withdrawReasonPrompt'))
        if (reason === null) return
        if (!reason.trim()) {
            alert(t('finance.fxPage.form.errReason'))
            return
        }

        startTransition(async () => {
            const result = await softDeleteFxRate(id, reason.trim())
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <Button
            variant="reversal"
            size="inline"
            onClick={handleClick}
            disabled={isPending}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </Button>
    )
}
