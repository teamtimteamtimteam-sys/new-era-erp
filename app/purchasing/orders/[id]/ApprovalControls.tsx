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
import ReasonPrompt from '@/app/components/ReasonPrompt'
import { approveOrder, rejectOrder } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function ApprovalControls({ poId }: { poId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function approve() {
        if (!window.confirm(t('purchasing.approveConfirm'))) return
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
                <button
                    type="button"
                    onClick={approve}
                    disabled={isPending}
                    className="border border-green-500 text-green-700 px-3 py-1.5 rounded text-sm hover:bg-green-50 disabled:opacity-50"
                >
                    {isPending ? t('common.saving') : t('purchasing.approveOrder')}
                </button>
                <ReasonPrompt
                    triggerLabel={t('purchasing.rejectOrder')}
                    title={t('purchasing.rejectConfirm')}
                    consequence={t('purchasing.rejectConsequence')}
                    confirmLabel={t('purchasing.rejectOrder')}
                    placeholder={t('purchasing.rejectReason')}
                    action={(reason) => rejectOrder(poId, reason)}
                    onDone={() => router.refresh()}
                />
            </div>
            {error && <p className="text-sm text-red-700 mt-2">{error}</p>}
        </div>
    )
}
