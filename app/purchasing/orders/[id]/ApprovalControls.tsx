'use client'

// SOD-1:批准 / 驳回一张【正在等审批】的采购单。
//
// 【这个控件此前不存在,而那是一条会搁死人的缺口】APR-2c 建了引擎与两支函数,
// app/ 里却一个调用方都没有(APPROVALS-SOD 实测)。审批关着时看不出来 ——
// 单据一提出来就是 approved。开关一旦打开,新单生为 draft/pending,
// 而屏幕上没有任何地方批得了它们,于是每一张新采购单都收不了货。
//
// 【禁用要说出为什么,不是把控件藏起来】本仓库的规矩:问题【不适用】才藏,
// 问题适用但【被挡住】就变灰加一句话(FIX-2 B1)。"这张单该不该批"对一张
// pending 的单永远是个适用的问题 —— 挡住它的可能是四眼、可能是级别不对,
// 而那两件都是服务端才知道的事,所以这里【不预判】:按钮亮着,拒绝由 DB 出,
// 就地显示。页面与服务端对同一条规矩各写一份,是本仓库付过四次账的形状。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { approveOrder, rejectOrder } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export default function ApprovalControls({ poId, subject }: { poId: string; subject: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function doApprove() {
        setError('')
        startTransition(async () => {
            const res = await approveOrder(poId, '')
            if (res?.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="border border-amber-300 bg-amber-50 rounded p-4 mb-4">
            <h2 className="font-semibold mb-1">{t('purchasing.approvalPanelTitle')}</h2>
            {/* 批准之前先说清楚它做了什么:把单据推到 confirmed,从此收得了货、付得了预付 */}
            <p className="text-xs text-gray-700 mb-3">{t('purchasing.approvalPanelWhat')}</p>
            <div className="flex flex-wrap items-start gap-3">
                <ConfirmButton
                    subject={subject}
                    title={t('purchasing.approveConfirm')}
                    body={t('purchasing.approvalPanelWhat')}
                    confirmLabel={t('purchasing.approveOrder')}
                    tier="destructive"
                    disabled={isPending}
                    className="border border-green-500 text-green-700 px-3 py-1.5 rounded text-sm hover:bg-green-50 disabled:opacity-50"
                    onConfirm={doApprove}
                >
                    {isPending ? t('common.saving') : t('purchasing.approveOrder')}
                </ConfirmButton>
                {/* ★ BTN-4:驳回这一半原来是 ReasonPrompt —— 同一页上两个确认长着
                    两副面孔(批准是对话框,驳回是就地展开的红面板)。折进来之后
                    两边是同一个对话框、同一格主语、同一条空白判据。
                    ☞ 主语用父组件已经传进来的 subject(po.code),与批准那一半
                      逐字相同 —— 一张单在两个动作里叫同一个名字。 */}
                <ConfirmButton
                    subject={subject}
                    title={t('purchasing.rejectConfirm')}
                    body={t('purchasing.rejectConsequence')}
                    confirmLabel={t('purchasing.rejectOrder')}
                    tier="destructive"
                    reason={{ placeholder: t('purchasing.rejectReason') }}
                    triggerVariant="destructive"
                    triggerSize="sm"
                    disabled={isPending}
                    onConfirm={(reason) => {
                        setError('')
                        startTransition(async () => {
                            const res = await rejectOrder(poId, reason)
                            if (res?.error) setError(res.error)
                            else router.refresh()
                        })
                    }}
                >
                    {t('purchasing.rejectOrder')}
                </ConfirmButton>
            </div>
            {error && <p className="text-sm text-red-700 mt-2">{error}</p>}
        </div>
    )
}
