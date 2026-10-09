'use client'

// 冲销按钮(danger outline;端口自 ReversePaymentButton):确认对话框后调
// reverseExpense,失败 alert;成功由 action 重定向到镜像单详情。
import { useTransition, type ReactNode } from 'react'
import { reverseExpense } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'

// MES-6a-1(Q33–Q37):对话框要一句理由(ConfirmContent.reason)—— 空着确认钮按不下去,理由原样交给 reverse_expense 的 p_memo,
//   存在原单的 reversal_reason 上,横幅与审计记录读它。正文里那一句提醒不要写健康细节(理由不遮,读这张单的人都看得见)。
// MES-5b-2(2026-10-09,Step 0 Q21 · Q22 · Q24):两样新东西,都由页面从数据库读到的事实给出 ——
//   consequence:按下之前说清后果(一张月结冲抵:冲掉它会把它冲抵过的 N 条估计放回"未结");
//   blocked:服务端【一定】拒的情形(电费单的费用单要在那张电费单的页面上撤回;经付款结过的要先冲付款;冲抵过预付款的)——
//   按钮看得见、按不下去、旁边印出为什么与走法(AGENTS.md「must not offer it ≠ must not show it」)。
//   它与权限码分开:PermissionGate 管"你有没有这个码",blocked 管"这张单此刻能不能冲",两件事不混成一个布尔。
export default function ReverseExpenseButton({ expenseId, subject, canEdit, consequence, blocked }: {
    expenseId: string; subject: string; canEdit: boolean; consequence?: string; blocked?: ReactNode
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doReverse(reason: string) {
        startTransition(async () => {
            const result = await reverseExpense(expenseId, reason)
            if (result?.error) {
                showActionMessage({
                    subject: subject,
                    headline: t('common.actionMessage.headline.notReversed'),
                    body: result.error,
                    detail: result.detail,
                })
            }
        })
    }

    // CONFIRM-1:★ 撤销档,不是破坏档 —— 冲销【不删任何东西】,原件与冲销件
    //   都留在账上,审计痕迹完整。BTN-1 为此另开了这一档,而确认钮取的正是
    //   【它所确认的那个动作】的档位。主语 = 单据代号(抬头里就印着它)。
    return (
        <div className="inline-flex flex-col items-end" data-control="reverse-expense">
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
        <ConfirmButton
            subject={subject}
            title={t('expense.reverseConfirm')}
            body={consequence ? `${consequence} ${t('expense.reverseReasonHint')}` : t('expense.reverseReasonHint')}
            reason={{ placeholder: t('expense.reverseReasonPlaceholder') }}
            confirmLabel={t('expense.reverse')}
            tier="destructive"
            triggerVariant="destructive"
            disabled={isPending || !!blocked}
            onConfirm={doReverse}
        >
            {isPending ? t('common.saving') : t('expense.reverse')}
        </ConfirmButton>
        </PermissionGate>
        {blocked && <p className="mt-1 max-w-md text-xs text-[color:var(--brand-muted-text)]" data-reverse-blocked="1">{blocked}</p>}
        </div>
    )
}
