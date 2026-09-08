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
import { showActionMessage } from '@/app/components/ui/action-message'

export default function ReopenForm({ periodEnd }: { periodEnd: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    // ════════════════════════════════════════════════════════════════════
    // ★【本处【没有】甲类的位置 —— 而这是一句实话,不是一个省略】★
    // ════════════════════════════════════════════════════════════════════
    //   Tim 在 ALERT-1 闸上把「重开原因」判成甲类:话要贴着那个输入框。
    //   但那个输入框【在 CONFIRM-1 的对话框里】(reason={{...}}),而本刀明令
    //   不许动那个组件;何况动作跑起来的时候对话框已经关了 —— 那个框不在屏幕上,
    //   贴无可贴。
    //   ☞ 而这一条本来也【到不了人面前】:对话框在理由为空时确认钮不可按
    //     (判据与 DB 的 btrim 同源)。它和 GST 那个空登记号一样,
    //     属于"界面已经拦住了"的那一类。
    //   ☞ 所以服务端仍然标着 field: 'reason'(那句标注是对的,值得留给下一个人),
    //     而这里落到页级横幅。**报告里点名了这一处**,没有假装它是甲类。
    function doReopen(reason: string) {
        startTransition(async () => {
            const result = await reopenPeriod(periodEnd, reason)
            if (result?.error) {
                showActionMessage({
                    subject: periodEnd,
                    headline: t('common.actionMessage.headline.notReopened'),
                    body: result.error,
                    detail: result.detail,
                })
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
