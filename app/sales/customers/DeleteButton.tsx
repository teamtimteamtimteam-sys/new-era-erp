'use client'

import { useTransition } from 'react'
import { softDeleteCustomer } from './actions'
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

    // CONFIRM-1:原来走的是原生确认框,消息键 customers.deleteConfirm。
    // 名字从【拼进句子】变成【对话框里自己的一格】—— 动作一个字没改。
    return (
        <ConfirmButton
            subject={legalName}
            title={t('customers.deleteConfirmTitle')}
            body={t('common.softDeleteNote')}
            details={
                <p className="text-sm font-medium text-[color:var(--brand-text)]">
                    {t('customers.deleteConsequence')}
                </p>
            }
            confirmLabel={t('common.delete')}
            tier="destructive"
            disabled={isPending}
            // ★★ BTN-FOLLOWUP(2026-09-20)· Tim 接受了这 +1.00px ★★
            //   BTN-TRIGGER-1 把这一处【转过去了 → 量了 → 按回来了】:行内档 20 → 22px,
            //   /sales/customers 的表体行高 42.42 → 43.42(**+1.00px,逐行**)。
            //   ★ Tim 裁的理由逐字是:**1px 在屏幕上看不见,而它买到的是三颗
            //     禁用之后不再读成「这里什么都没有」的控件。**
            //   ☞ 于是那处 `disabled:text-gray-400`(2.602 白底 / 2.443 品牌底,都过不了 AA)结清了:
            //     行内档禁用后字色是 --color-disabled-text,实测 14.132 / 13.272 ✓。
            triggerVariant="destructive"
            triggerSize="inline"
            onConfirm={() => {
                startTransition(async () => {
                    const result = await softDeleteCustomer(id)
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
