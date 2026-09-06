'use client'

// AUDEL-2:删除前先问【为什么】—— AUDEL-1b 把理由做成必填,而当时没有输入框,
// 这个按钮从那时起一直被数据库按名拒。本文件是那个缺口的修补。
// 【软删,不是硬删】它保留记录、写一条 writeoff 流水,并记下谁与为什么。
//
// ★ BTN-4:从 ReasonPrompt 折进 <ConfirmButton reason>。同一个理由能力,
//   一份实现 —— 见 app/components/ui/confirm-dialog.tsx 抬头。
//   ☞ 主语从标题里搬出来了:原来是 `inbound.deleteConfirm` 把批号拼进那句问话,
//     现在批号占 subject 自己那一格(对话框里那条竖线框住的就是它),
//     标题退回成不含主语的 `deleteConfirmTitle`。
//   ☞ 【错误显示的位置变了,而这是折进来的代价,不是缺陷】ReasonPrompt 会把
//     服务端那句话显示在【展开着的面板里】,面板不关、理由还在。ConfirmButton
//     照 CONFIRM-1 的裁定在同一次手势里关掉对话框再跑动作(见抬头「为什么不走
//     await」),所以拒绝改为显示在按钮【旁边】—— 与 ApprovalControls 已经
//     在用的形状逐字相同,不是本文件独有的第二种写法。
import { useState, useTransition } from 'react'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { softDeleteInbound } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id, code }: { id: string; code: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    return (
        <span className="inline-flex flex-col items-start">
            <ConfirmButton
                subject={code}
                title={t('inbound.deleteConfirmTitle')}
                body={t('inbound.deleteConsequence')}
                confirmLabel={t('common.delete')}
                tier="destructive"
                reason={{ placeholder: t('inbound.deleteReasonPlaceholder') }}
                triggerVariant="destructive"
                triggerSize="inline"
                disabled={isPending}
                onConfirm={(reason) => {
                    setError('')
                    startTransition(async () => {
                        const res = await softDeleteInbound(id, reason)
                        // 【服务端拒了就把服务端那句话原样显示】它已经按名翻译过。
                        if (res && 'error' in res && res.error) setError(res.error)
                    })
                }}
            >
                {isPending ? t('common.deleting') : t('common.delete')}
            </ConfirmButton>
            {error && <span className="mt-1 text-xs text-destructive-text">{error}</span>}
        </span>
    )
}
