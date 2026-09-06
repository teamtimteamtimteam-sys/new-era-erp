'use client'

// ★★ BTN-4:全树最后一个原生【输入型】对话框在这里退休 ★★
//
// 转换前:`window.prompt` 拿理由 + `alert` 报空白。两条毛病,而第二条是本刀的委托书:
//   ① 它拿不到本地化的说明文字,也没法在理由为空时禁用提交 —— 只能【先让人按下去】
//      再用一个 alert 把人赶回来。ReasonPrompt 的抬头早把这一条写清楚了。
//   ② ★【原生对话框对交互探针是隐形的】★ 探针点不到 window.prompt,
//      于是"撤销一条牌价"这一步【一次都没有被机器走过】—— 与 CONFIRM-1
//      抬头第 ③ 条、FIX-2b 的 SMOKE-SINGLE-ROLE-BLINDSPOT 是同一个形状。
//      换成 ConfirmDialog 之后它是真 DOM,BTN-4 已用探针端到端走过一次。
//
// ★【档位不动:reversal,不是 destructive】★ BTN-3 已经裁过,本刀不重裁。
//   它脸上写着 Delete、画成红的,但 `softDeleteFxRate` 保留记录与理由 ——
//   **虚线竖条(撤销)才是实话**。标签仍然是错的,那是 COPY 的活,不是这一刀的。
//
// 【空白判据抄的是同一条】`reason.trim() === ''` 由 ConfirmDialog 自己执行,
//   与 db 的 `p_reason IS NULL OR btrim(p_reason) = ''` 逐字对应。
//   所以转换前那个 `alert(errReason)` 【跟着删掉】:它守的那道闸移进了对话框,
//   而确认钮在理由为空时按不动 —— 一个必然被拒的动作不该有可提交的控件。
//   ☞ `alert(result.error)` 留着:那是【报告服务端的拒绝】,不是确认,
//     归 CONFIRM-1-ALERT-HALF 那一条(known-issues)统一处理,不在本刀。
import { useTransition } from 'react'
import { softDeleteFxRate } from './actions'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { useTranslations } from '@/lib/i18n/client'

export default function DeleteButton({ id, subject }: { id: string; subject: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()

    return (
        <ConfirmButton
            subject={subject}
            title={t('finance.fxPage.withdrawConfirmTitle')}
            body={t('finance.fxPage.withdrawConsequence')}
            confirmLabel={t('common.delete')}
            tier="reversal"
            reason={{ placeholder: t('finance.fxPage.withdrawReasonPrompt') }}
            triggerVariant="reversal"
            triggerSize="inline"
            disabled={isPending}
            onConfirm={(reason) => {
                startTransition(async () => {
                    const result = await softDeleteFxRate(id, reason.trim())
                    // ☞ 这一句原样留着 —— 见抬头:它报告的是【服务端的拒绝】,
                    //   不是一次确认。归 CONFIRM-1-ALERT-HALF,不在本刀。
                    if (result?.error) alert(result.error)
                })
            }}
        >
            {isPending ? t('common.deleting') : t('common.delete')}
        </ConfirmButton>
    )
}
