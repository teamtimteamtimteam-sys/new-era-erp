'use client'

// 删除对账单按钮(destructive 档):确认后调 deleteStatement,失败 alert
// (已对账的报表会被 DB 守卫拒绝);成功由 action 跳列表。
// CONFIRM-1:主语是报表代号 —— 同一页的 bank.reconcileConfirm 早就在用 {code},
// 而【删除】这一处此前一个字都不说。
import { useTransition } from 'react'
import { deleteStatement } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function DeleteStatementButton({ statementId, subject ,
canEdit
}: { statementId: string; subject: string 
canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
        <ConfirmButton
            subject={subject}
            title={t('bank.deleteConfirm')}
            body={t('common.softDeleteNote')}
            confirmLabel={t('common.delete')}
            tier="destructive"
            triggerVariant="destructive"
            triggerSize="sm"
            disabled={isPending}
            onConfirm={() => {
                startTransition(async () => {
                    const result = await deleteStatement(statementId)
                    if (result?.error) {
                        showActionMessage({
                            subject: subject,
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
        </PermissionGate>
    )
}
