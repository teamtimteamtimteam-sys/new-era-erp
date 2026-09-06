'use client'

// 冲销按钮(danger outline):确认对话框后调 reverseEntry,失败 alert
// (端口自 inbound/DeleteButton);成功由 action 重定向到冲销单详情。
import { useTransition } from 'react'
import { reverseEntry } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function ReverseButton({ entryId, subject }: { entryId: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doReverse() {
        startTransition(async () => {
            const result = await reverseEntry(entryId)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    // CONFIRM-1:★ 撤销档,不是破坏档 —— 冲销【不删任何东西】,原件与冲销件
    //   都留在账上,审计痕迹完整。BTN-1 为此另开了这一档,而确认钮取的正是
    //   【它所确认的那个动作】的档位。主语 = 单据代号(抬头里就印着它)。
    return (
        <ConfirmButton
            subject={subject}
            title={t('finance.reverseConfirm')}
            confirmLabel={t('finance.reverse')}
            tier="reversal"
            triggerVariant="reversal"
            triggerSize="sm"
            disabled={isPending}
            onConfirm={doReverse}
        >
            {isPending ? t('common.saving') : t('finance.reverse')}
        </ConfirmButton>
    )
}
