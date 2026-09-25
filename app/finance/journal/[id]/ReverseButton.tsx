'use client'

// 冲销按钮 —— ★ APR-6(Tim 2026-09-25,grilling Q6):从这里冲一张分录 = 【提一张冲销申请】,
//   CFO 批准那一刻才冲(矩阵「手工凭证与冲销 | 财务 | CFO」)。确认对话框要一句理由(它写进冲销分录的摘要),
//   冲销日 = 今天的业务日,随申请冻结。审批关着时申请生下来就批准并当场冲销,跳到冲销分录。
//
// 【钮灰不灰、说什么,读的是库的同一份判据】journal_entry_reversal_route(页面在服务端问它):
//   · 'source_path' —— 这张分录由一张有自己冲销路径的单据过出来(付款、转账、预提税汇缴、收货定价、发票、
//     贷项、开支、运费、成本分摊、加工成本、年结、工资过账):钮【看得见、按不动、带理由】(DBLOCK-1),
//     理由按 source_type 指路。此前这里只认三种(付款 · 转账 · 预提税),库却拒得更多 —— 按下去才报错;
//     APR-6 让屏幕与库问同一个问题。
//   · 已经挂着一张在等的冲销申请 —— 灰掉,说出那一张的编号。
//   · 'request' —— 可以提;没有 module.finance.edit 的人看得见、按不动、带理由。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { requestReversal } from '../requestActions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Button } from '@/app/components/ui/button'

export default function ReverseButton({ entryId, subject, canEdit, route, sourceType, openRequestLabel }: {
    entryId: string
    subject: string
    canEdit: boolean
    /** journal_entry_reversal_route 的答案 */
    route: 'request' | 'source_path'
    sourceType: string | null
    /** 这张分录上已经在等的冲销申请(没有为 null) */
    openRequestLabel: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()

    function doRequest(reason: string) {
        startTransition(async () => {
            const result = await requestReversal(entryId, reason)
            if (result?.error) {
                showActionMessage({
                    subject: subject,
                    headline: t('common.actionMessage.headline.notReversed'),
                    body: result.error,
                    detail: result.detail,
                })
                return
            }
            if (result.request?.status === 'approved' && result.request.entryId) {
                router.push(`/finance/journal/${result.request.entryId}`)
                return
            }
            router.refresh()
        })
    }

    if (route === 'source_path' || openRequestLabel) {
        return (
            <span className="inline-flex flex-col items-start gap-1.5">
                <Button type="button" variant="destructive" disabled>
                    {t('finance.journalRequest.requestReversal')}
                </Button>
                <span className="text-xs text-[color:var(--brand-muted-text)] max-w-xs">
                    {openRequestLabel
                        ? t('finance.journalRequest.reversalWaiting', { label: openRequestLabel })
                        : t('finance.reverseUseSourcePath.' + (sourceType ?? 'payment'))}
                </span>
            </span>
        )
    }

    // CONFIRM-1:★ 撤销档,不是破坏档 —— 冲销【不删任何东西】,原件与冲销件都留在账上。
    //   主语 = 单据代号(抬头里就印着它)。理由必填:它进冲销分录的摘要,也是 CFO 批的时候读的那一句。
    return (
        <PermissionGate code="module.finance.edit" allowed={canEdit}>
            <ConfirmButton
                subject={subject}
                title={t('finance.journalRequest.reversalConfirm')}
                body={t('finance.journalRequest.reversalBody')}
                confirmLabel={t('finance.journalRequest.requestReversal')}
                tier="reversal"
                triggerVariant="destructive"
                reason={{ placeholder: t('finance.journalRequest.reversalPlaceholder') }}
                disabled={isPending}
                onConfirm={doRequest}
            >
                {isPending ? t('common.saving') : t('finance.journalRequest.requestReversal')}
            </ConfirmButton>
        </PermissionGate>
    )
}
