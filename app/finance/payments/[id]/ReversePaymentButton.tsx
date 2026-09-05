'use client'

// 冲销按钮(danger outline;端口自 journal ReverseButton):window.confirm 后调
// reversePayment,失败 alert;成功由 action 重定向到镜像单详情。
import { useTransition } from 'react'
import { reversePayment } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function ReversePaymentButton({ paymentId }: { paymentId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function handleClick() {
        const confirmed = window.confirm(t('finance.reversePaymentConfirm'))
        if (!confirmed) return

        startTransition(async () => {
            const result = await reversePayment(paymentId)
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
            {isPending ? t('common.saving') : t('finance.reversePayment')}
        </Button>
    )
}
