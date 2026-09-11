'use client'

// 软删定价公式(danger outline;端口自 ReversePaymentButton):确认后调
// deleteFormula,失败 alert;成功由 action 跳回列表。
// CONFIRM-1:主语是公式代号 —— 父页的标题里就印着它,原来却没有传进来。
import { useTransition } from 'react'
import { deleteFormula } from '../../actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'

export default function DeleteFormulaButton({ formulaId, subject }: { formulaId: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    return (
        <ConfirmButton
            subject={subject}
            title={t('pricing.deleteConfirm')}
            body={t('common.softDeleteNote')}
            details={
                <p className="text-sm font-medium text-[color:var(--brand-text)]">
                    {t('pricing.deleteConsequence')}
                </p>
            }
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            className="border border-red-300 text-red-600 px-3 py-2 rounded hover:bg-red-50 disabled:opacity-50"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await deleteFormula(formulaId)
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
    )
}
