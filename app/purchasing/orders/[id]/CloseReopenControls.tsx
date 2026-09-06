'use client'

// 结束 / 重新打开采购单(cut 4c)。
// 结束:有未抵扣预付时把金额醒目摆出来,说明必填,填了才让按 —— 那是躺在 1300 里
// 的真钱,这张单不会再吸收它了,不许无声搁浅。没有未抵扣预付时,一次 confirm 即可。
// 重新打开:确认对话框里问原因。
//
// CONFIRM-1:两处都换成 ConfirmButton,主语都是【单号】(po.code,由页面传进来 ——
//   与同一页的 ApprovalControls 同一个约定)。
//   ★ 关单那一侧的「关单说明」留在面板里【没有搬进对话框】:它不是一句理由,
//     它是给未抵扣预付留的记录,而对话框只放得下一个理由框。搬一半更坏。
//   ★ 重开那一侧的原因搬进了对话框(只有它一个必填项,搬得干净)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { closeOrder, reopenOrder } from './actions'

export function CloseOrderControl({
    poId,
    subject,
    unappliedPrepayment,
    baseCurrency,
}: {
    poId: string
    /** CONFIRM-1:这一次结束的是【哪一张单】—— 单号,页面抬头里就印着它。 */
    subject: string
    /** OPS-14:null = 读者没有 module.finance.view,【未抵扣预付未知】。
     *  未知按"有"处理 —— 关单说明是给未抵扣预付留的记录,漏掉它比多写一句糟。 */
    unappliedPrepayment: number | null
    /** CCY-1:未抵扣预付是本位币(prepaid_remaining_base)。那句警告里没有别的地方
     *  写着币种,而这一页的抬头写的是【单据币种】—— 借它就等于说错话。
     *  本位币来自 currencies.is_base,由页面传进来(客户端组件不自己查)。 */
    baseCurrency: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [notes, setNotes] = useState('')
    const [error, setError] = useState('')

    const needsNotes = unappliedPrepayment === null || unappliedPrepayment > 0
    const canSubmit = !needsNotes || notes.trim() !== ''

    function onClose() {
        startTransition(async () => {
            const res = await closeOrder(poId, notes)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    if (!open) {
        return (
            <button
                type="button"
                onClick={() => setOpen(true)}
                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
            >
                {t('purchasing.close')}
            </button>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-3 text-sm space-y-2 max-w-md">
            {needsNotes && (
                <p className="text-amber-800 bg-amber-50 border border-amber-300 rounded px-3 py-2">
                    {unappliedPrepayment === null
                        ? t('purchasing.closeWithPrepaymentUnknown')
                        : t('purchasing.closeWithPrepaymentWarning', {
                              amount: formatAmount(unappliedPrepayment, baseCurrency),
                          })}
                </p>
            )}
            <div>
                <label className="block text-xs text-gray-600 mb-1">{t('purchasing.closeNotes')}</label>
                <input
                    type="text"
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                    className="w-full border border-gray-300 px-3 py-1.5 rounded"
                />
            </div>
            {error && <p className="text-red-600">{error}</p>}
            <div className="flex gap-2">
                <ConfirmButton
                    subject={subject}
                    title={t('purchasing.closeConfirm')}
                    confirmLabel={t('purchasing.close')}
                    tier="destructive"
                    onConfirm={onClose}
                    disabled={isPending || !canSubmit}
                    className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {t('purchasing.close')}
                </ConfirmButton>
                {/* FIX-2(B3/F):【禁用了就说为什么】此前这个按钮会变灰而一言不发 ——
                    上面那条琥珀色提示解释的是"还有多少预付没抵扣",
                    而【为什么点不动】另有其因:需要一句说明。 */}
                {!canSubmit && !isPending && (
                    <span className="self-center text-xs text-amber-700">
                        {t('purchasing.closeNeedsNotes')}
                    </span>
                )}
                <button
                    type="button"
                    onClick={() => setOpen(false)}
                    className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50"
                >
                    {t('common.cancel')}
                </button>
            </div>
        </div>
    )
}

export function ReopenOrderControl({ poId, subject }: { poId: string; subject: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function onReopen(reason: string) {
        startTransition(async () => {
            const res = await reopenOrder(poId, reason)
            if (res.error) setError(res.error)
            else router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-2">
            {/* CONFIRM-1:原因输入框与它的 FIX-2 说明一起搬进了对话框 ——
                对话框自己带同一条空白判据、同一句"为什么按不动"。
                传给 reopenOrder 的仍是同一个字符串、同一个参数位。 */}
            <ConfirmButton
                subject={subject}
                title={t('purchasing.reopenConfirm')}
                confirmLabel={t('purchasing.reopen')}
                tier="reversal"
                reason={{ placeholder: t('purchasing.reopenReason') }}
                onConfirm={onReopen}
                disabled={isPending}
                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm disabled:opacity-50"
            >
                {t('purchasing.reopen')}
            </ConfirmButton>
            {error && <span className="text-sm text-red-600">{error}</span>}
        </div>
    )
}
