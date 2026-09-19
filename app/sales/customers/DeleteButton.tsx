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
            // ★ BTN-TRIGGER-1(2026-09-20):这一处【转过去了 → 量了 → 按回来了】。
            //   `triggerVariant="destructive" triggerSize="inline"` 会把它从 20px 变成 22px,
            //   而实测 /sales/customers 的表体行高因此 42.42 → 43.42(**+1.00px,逐行**)。
            //   委托书 §3:「共享组件复刻不出当前几何就停下来把差值报出来,不要接受它」——
            //   这正是 POLISH-1 对排序表头钮做过的那一步。行高是停止条件 (c) 的触发器。
            //   ☞ 代价照直记:它那处 `disabled:text-gray-400` 因此【活着】(2.602 白底 / 2.443 品牌底,都过不了 AA)。
            //   登记在 docs/known-issues.md 的 BTNTRIGGER1-INLINE-ADDS-1PX-IN-LIST-ROWS。
            className="text-red-600 hover:underline disabled:text-gray-400"
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
