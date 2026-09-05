'use client'

// SO-4b:谢绝。【理由必填】—— 一张没有理由的谢绝,三个月后没有人说得出
// 对方为什么没买。服务端按名拒 QT_DECLINE_REASON_REQUIRED,这里在按下之前
// 就把钮禁掉,不让人先撞一次。
//
// 【过期的报价也谢绝得了,这是有意的】过期只是日历走过去了,而"对方明确说
// 不要"是一个真实发生的事实 —— 拒绝记录它只会让那条信息无处安放。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { declineQuote } from '../actions'
import { Button } from '@/app/components/ui/button'

export default function DeclineControl({ quoteId }: { quoteId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')
    const [error, setError] = useState('')

    function go() {
        setError('')
        startTransition(async () => {
            const res = await declineQuote(quoteId, reason)
            if (res.error) setError(res.error)
            else { setOpen(false); setReason(''); router.refresh() }
        })
    }

    if (!open) {
        return (
            <button type="button" onClick={() => setOpen(true)}
                    className="text-blue-600 hover:underline text-sm">
                {t('quotes.decline.action')}
            </button>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-3">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            <div className="flex flex-wrap items-end gap-3">
                <div className="flex-1 min-w-[16rem]">
                    <label className="block text-xs text-gray-600 mb-1">
                        {t('quotes.decline.reason')} <span className="text-red-600">*</span>
                    </label>
                    <input type="text" value={reason} onChange={(e) => setReason(e.target.value)}
                           className="w-full border border-gray-300 px-2 py-1 rounded text-sm" />
                </div>
                <Button variant="secondary" size="sm" type="button" onClick={go} disabled={isPending || reason.trim() === ''}>
                    {isPending ? t('common.saving') : t('quotes.decline.action')}
                </Button>
                <button type="button" onClick={() => setOpen(false)}
                        className="text-gray-500 hover:underline text-xs">
                    {t('common.cancel')}
                </button>
            </div>
            <p className="text-xs text-gray-500 mt-2">
                {reason.trim() === '' ? t('quotes.decline.needsReason') : t('quotes.decline.consequence')}
            </p>
        </div>
    )
}
