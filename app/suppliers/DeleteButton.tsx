'use client'

import { useTransition } from 'react'
import { softDeleteSupplier } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'

export default function DeleteButton({
    id,
    legalName,
}: {
    id: string
    legalName: string
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    // CONFIRM-1:原来走的是原生确认框,消息键 suppliers.deleteConfirm。
    // 名字从【拼进句子】变成【对话框里自己的一格】—— 动作一个字没改。
    return (
        <ConfirmButton
            subject={legalName}
            title={t('suppliers.deleteConfirmTitle')}
            body={t('common.softDeleteNote')}
            details={
                <p className="text-sm font-medium text-[color:var(--brand-text)]">
                    {t('suppliers.deleteConsequence')}
                </p>
            }
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            // ★★ BTN-FOLLOWUP(2026-09-20)· Tim 接受了这 +1.00px ★★
            //   /suppliers 的表体行高 42.42 → 43.42(**+1.00px,逐行**)。
            //   与 app/sales/customers/DeleteButton.tsx 是同一格同一条裁定,理由见那里。
            //   ☞ `disabled:text-gray-400`(2.602 / 2.443)结清:行内档实测 14.132 / 13.272 ✓。
            triggerVariant="destructive"
            triggerSize="inline"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await softDeleteSupplier(id)
                    if (result?.error) {
                        showActionMessage({
                            subject: legalName,
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
