'use client'

// 重新打开已对账报表:确认对话框里问理由,再调 unreconcileStatement。
// 理由必填(DB 侧 REASON_REQUIRED 兜底),成功后 revalidate 让页面回到 open 状态。
//
// ★【CONFIRM-1:三步变一步】★
//   原来是「按一次展开 → 敲理由 → 再按一次 → 原生确认框又问一次」。
//   中间那个展开面板存在的唯一理由是【没地方放理由输入框】,而对话框现在有。
//   于是展开态整个消失:一枚按钮,一个对话框,理由与确认在同一处问。
//   ☞ 传给 unreconcileStatement 的仍是 reason.trim(),同一个参数位、同一个值。
//   ☞ 消息 bank.unreconcileConfirm('Reopen this statement for editing?')
//     【一个字没改】—— 它不说后果,而重写它是 COPY-2 的事,不是本刀的。
import { useTransition } from 'react'
import { unreconcileStatement } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function UnreconcileControl({
    statementId,
    subject,
}: {
    statementId: string
    /** CONFIRM-1:重新打开的是【哪一份报表】—— 报表代号,抬头里就印着它。 */
    subject: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doUnreconcile(reason: string) {
        startTransition(async () => {
            const result = await unreconcileStatement(statementId, reason.trim())
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <ConfirmButton
            subject={subject}
            title={t('bank.unreconcileConfirm')}
            confirmLabel={t('bank.unreconcile')}
            tier="reversal"
            reason={{ placeholder: t('bank.unreconcileReasonPlaceholder') }}
            disabled={isPending}
            onConfirm={doUnreconcile}
            className="border border-gray-300 px-3 py-1 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
        >
            {isPending ? t('common.saving') : t('bank.unreconcile')}
        </ConfirmButton>
    )
}
