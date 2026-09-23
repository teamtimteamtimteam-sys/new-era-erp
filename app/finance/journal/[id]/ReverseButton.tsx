'use client'

// 冲销按钮(danger outline):确认对话框后调 reverseEntry,失败 alert
// (端口自 inbound/DeleteButton);成功由 action 重定向到冲销单详情。
import { useTransition } from 'react'
import { reverseEntry } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Button } from '@/app/components/ui/button'

export default function ReverseButton({ entryId, subject ,
canEdit, sourcePath,
}: { entryId: string; subject: string 
canEdit: boolean
/** PAY-REQ-1:付款、转账或(Batch B 起)代扣税缴纳过出来的分录不许在这里冲 —— reverse_journal_entry 按名拒
 *  (JE_REVERSE_USE_SOURCE_PATH)。给了它,钮【看得见、按不动、带理由】(DBLOCK-1)。 */
sourcePath?: 'payment' | 'transfer' | 'wht_remittance'
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doReverse() {
        startTransition(async () => {
            const result = await reverseEntry(entryId)
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

    // ★ PAY-REQ-1(Tim 2026-09-23):钱离开之前要先批。一笔付款的分录若能在这里冲,
    //   就绕开了冲销申请那一道审批 —— 所以库拒它,而屏幕【在按之前】就说出来:
    //   钮留着、灰掉、旁边一行说去哪冲。不藏(DBLOCK-1:藏起来教给人的是"这件事不存在")。
    //   判据与库同源:source_type 是 'payment'、'transfer' 或(Batch B 起)'wht_remittance'。
    if (sourcePath) {
        return (
            <span className="inline-flex flex-col items-start gap-1.5">
                <Button type="button" variant="destructive" disabled>
                    {t('finance.reverse')}
                </Button>
                <span className="text-xs text-[color:var(--brand-muted-text)] max-w-xs">
                    {sourcePath === 'payment'
                        ? t('finance.reverseUseSourcePathPayment')
                        : sourcePath === 'transfer'
                            ? t('finance.reverseUseSourcePathTransfer')
                            : t('finance.reverseUseSourcePathWht')}
                </span>
            </span>
        )
    }

    // CONFIRM-1:★ 撤销档,不是破坏档 —— 冲销【不删任何东西】,原件与冲销件
    //   都留在账上,审计痕迹完整。BTN-1 为此另开了这一档,而确认钮取的正是
    //   【它所确认的那个动作】的档位。主语 = 单据代号(抬头里就印着它)。
    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
        <ConfirmButton
            subject={subject}
            title={t('finance.reverseConfirm')}
            body={t('finance.reverseConsequence')}
            confirmLabel={t('finance.reverse')}
            tier="destructive"
            triggerVariant="destructive"
            disabled={isPending}
            onConfirm={doReverse}
        >
            {isPending ? t('common.saving') : t('finance.reverse')}
        </ConfirmButton>
        </PermissionGate>
    )
}
