'use client'

// 化验详情页的两个动作:立即应用 / 撤销应用。
// 撤销在确认对话框里问原因,并挂着醒目的提醒:撤销【不回价】。
//
// CONFIRM-1:原因输入框搬进对话框(见 finance/close/ReopenForm.tsx 的说明)。
//   ☞ assay.unapplyNote(「不回价」那一句)【留在页面上】,没有搬进对话框:
//     assay.unapplyConfirm 本身不说后果,而重写那一句是 COPY-2 的事。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { applyAssay, unapplyAssay } from '../actions'

// blocked:预览已经报出提交会拒的理由(ASY-1)。理由横幅由页面渲染,这里只让
// 按钮跟着它走 —— 灰而不语在别处是病,这里不是:红横幅就在按钮上方。
export function ApplyNowButton({
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
            const res = await applyAssay(assayId, batchId)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3">
            <button
                type="button"
                onClick={onApply}
                disabled={isPending || blocked}
                className={
                    blocked
                        ? 'border border-gray-300 px-4 py-2 rounded disabled:text-gray-400'
                        : 'bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400'
                }
            >
                {isPending ? t('common.saving') : t('assay.applyNow')}
            </button>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}

export function UnapplyControl({
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
            const res = await unapplyAssay(assayId, batchId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="space-y-2">
            <p className="text-xs text-gray-500">{t('assay.unapplyNote')}</p>
            <div className="flex flex-wrap items-center gap-2">
                <ConfirmButton
                    subject={subject}
                    title={t('assay.unapplyConfirm')}
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
