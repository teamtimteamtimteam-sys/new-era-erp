'use client'

// 行内重开:确认对话框里问理由,再调 reopenPeriod,失败 alert。
//
// ★【CONFIRM-1:那个理由输入框搬进了对话框】★
//   原来的形状是「先在页面上敲理由 → 按钮才亮 → 原生确认框再问一次要不要」。
//   两步问的是同一件事,而【灰盒子那一步答不出重开的是哪一个期间】。
//   现在只剩一步:按下去,对话框点名那个期间,并在同一处要那句理由;
//   理由为空时确认钮不可按(判据 reason.trim() === '' 与 DB 的 btrim 同源)。
//   ☞ 传给 reopenPeriod 的仍是同一个字符串、同一个位置,动作本身一个字没改。
//   (DB 端 REASON_REQUIRED 仍是权威的第二道防线。)
import { useTransition } from 'react'
import { reopenPeriod } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function ReopenForm({ periodEnd }: { periodEnd: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    function doReopen(reason: string) {
        startTransition(async () => {
            const result = await reopenPeriod(periodEnd, reason)
            if (result?.error) {
                alert(result.error)
            }
        })
    }

    return (
        <div className="flex items-center gap-2">
            <ConfirmButton
                subject={periodEnd}
                title={t('finance.reopenConfirm')}
                confirmLabel={t('finance.reopenButton')}
                tier="reversal"
                reason={{ placeholder: t('finance.reopenReason') }}
                disabled={isPending}
                onConfirm={doReopen}
                className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 disabled:opacity-50"
            >
                {isPending ? t('common.saving') : t('finance.reopenButton')}
            </ConfirmButton>
        </div>
    )
}
