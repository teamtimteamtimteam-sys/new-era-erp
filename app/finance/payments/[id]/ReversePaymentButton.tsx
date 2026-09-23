'use client'

// ★ PAY-REQ-1(Tim 2026-09-23):「冲销」变成「申请冲销」—— 确认对话框要一句理由
// (必填),提一张冲销申请;CFO 批准后由财务在申请页上执行。成功由 action 重定向到申请页。
import { useTransition } from 'react'
import { requestPaymentReversal } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function ReversePaymentButton({ paymentId, subject ,
canEdit
}: { paymentId: string; subject: string 
canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doRequest(reason: string) {
        startTransition(async () => {
            const result = await requestPaymentReversal(paymentId, reason)
            if (result?.error) {
                showActionMessage({
                    subject: subject,
                    headline: t('common.actionMessage.headline.notReversalRequested'),
                    body: result.error,
                    detail: result.detail,
                })
            }
        })
    }

    // CONFIRM-1:★ 撤销档 —— 申请本身什么都不动(不过账、不改付款),
    //   真正的冲销在批准之后才发生。主语 = 付款单代号(抬头里就印着它)。
    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
        <ConfirmButton
            subject={subject}
            title={t('finance.requestReversalConfirm')}
            body={t('finance.requestReversalBody')}
            confirmLabel={t('finance.requestReversal')}
            tier="reversal"
            reason={{ placeholder: t('finance.requestReversalPlaceholder') }}
            triggerVariant="reversal"
            disabled={isPending}
            onConfirm={doRequest}
        >
            {isPending ? t('common.saving') : t('finance.requestReversal')}
        </ConfirmButton>
        </PermissionGate>
    )
}
