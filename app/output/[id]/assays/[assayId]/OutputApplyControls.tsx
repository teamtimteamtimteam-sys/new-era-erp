'use client'

// 产出化验详情页的两个动作:立即应用 / 撤销应用。
// 进料侧 ApplyAssayControls 是形状的出处;撤销在确认对话框里问原因,
// 并挂着提醒:撤销【不回含量】—— 含量退到哪一版是新化验或手工格子的显式动作。
//
// CONFIRM-1:与进料侧逐字同形 —— 原因搬进对话框,那句提醒留在页面上。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { applyOutputAssayAction, unapplyOutputAssayAction } from '../actions'
import { Button } from '@/app/components/ui/button'

// blocked:试算已经报出应用会拒的理由(与应用同一串拒绝 —— fixture 54 I 臂)。
// 理由横幅由页面渲染,这里只让按钮跟着它走。
export function ApplyOutputAssayButton({
    assayId,
    batchId,
    blocked = false,
}: {
    assayId: string
    batchId: string
    blocked?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onApply() {
        startTransition(async () => {
            const res = await applyOutputAssayAction(assayId, batchId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <Button
                type="button"
                onClick={onApply}
                disabled={isPending || blocked}
                variant={blocked ? 'secondary' : 'default'} size="default"
            >
                {isPending ? t('common.saving') : t('assay.applyNow')}
            </Button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnapplyOutputAssayControl({
    assayId,
    batchId,
    subject,
}: {
    assayId: string
    batchId: string
    /** CONFIRM-1:撤销的是【哪一张化验单】—— 化验代号 · 批号,抬头里两个都印着。
     *  ★ 主语里【没有价】:这一页的单价走 MaskedValue(data.view_prices),
     *    而主语是无条件渲染的 —— 把价放进来就是绕过遮蔽。 */
    subject: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onUnapply(reason: string) {
        startTransition(async () => {
            const res = await unapplyOutputAssayAction(assayId, batchId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            <p className="text-xs text-gray-500">{t('assay.output.unapplyNote')}</p>
            <div className="flex flex-wrap items-center gap-2">
                <ConfirmButton
                    subject={subject}
                    title={t('assay.output.unapplyConfirm')}
                    confirmLabel={t('assay.unapply')}
                    tier="reversal"
                    reason={{ placeholder: t('assay.unapplyReason') }}
                    onConfirm={onUnapply}
                    disabled={isPending}
                    className="border border-red-300 text-red-600 px-3 py-1.5 rounded hover:bg-red-50 text-sm disabled:opacity-50"
                >
                    {t('assay.unapply')}
                </ConfirmButton>
                {error && <span className="text-sm text-red-600">{error}</span>}
            </div>
        </div>
    )
}
