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
//   ☞ 而【报告服务端拒绝】的那一句 BTN-4 留着没动,归 CONFIRM-1-ALERT-HALF
//     那一条(known-issues)统一处理 —— **ALERT-1 就是那一刀,它现在走横幅。**
//
// ★★【ALERT-1 在这个文件上栽了一跤,而它正是 AGENTS.md 记过的那一条】★★
//   本刀的批量改写脚本按正则找那句原生调用,而【它先撞上的是上面这段注释】——
//   BTN-4 为了说明"哪一句留着"把那个调用【逐字写进了注释】。于是脚本改了注释、
//   放过了真正的代码,构建当场语法错。
//   这与 CONFIRM-1 被注释多数出 16 处、与本刀开工时 grep 报 20 而真数 18,
//   是同一条法则的第三次、第四次出现:**注释里写下那个字面 token,
//   就是在给将来所有按字面找它的机器下绊子。**
//   ☞ 所以这一段现在【不含】任何可执行形状的调用文本。
import { useTransition } from 'react'
import { softDeleteFxRate } from './actions'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { useTranslations } from '@/lib/i18n/client'
import { showActionMessage } from '@/app/components/ui/action-message'

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
                    // ALERT-1:这一句就是抬头说的"归 CONFIRM-1-ALERT-HALF"的那一句。
                    if (result?.error) {
                        showActionMessage({
                            subject: subject,
                            headline: t('common.actionMessage.headline.notWithdrawn'),
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
