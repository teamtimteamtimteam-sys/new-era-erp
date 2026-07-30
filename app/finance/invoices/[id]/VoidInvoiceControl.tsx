'use client'

// 作废发票:内联理由输入 + window.confirm,再调 voidInvoice。
// 理由必填(DB 侧 REASON_REQUIRED 兜底);成功后 revalidate 让页面切到已作废状态。
import { useState, useTransition } from 'react'
import { voidInvoice } from './actions'
import { useTranslations } from '@/lib/i18n/client'

export default function VoidInvoiceControl({ invoiceId }: { invoiceId: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')

    function handleSubmit() {
        if (!window.confirm(t('invoice.voidConfirm'))) return
        startTransition(async () => {
            const result = await voidInvoice(invoiceId, reason.trim())
            if (result?.error) {
                alert(result.error)
            } else {
                setOpen(false)
                setReason('')
            }
        })
    }

    if (!open) {
        return (
            <button
                type="button"
                onClick={() => setOpen(true)}
                className="border border-red-300 text-red-600 px-3 py-1 rounded hover:bg-red-50 text-sm"
            >
                {t('invoice.void')}
            </button>
        )
    }

    return (
        <span className="flex flex-wrap items-center gap-2">
            <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder={t('invoice.voidReason')}
                className="border border-gray-300 px-3 py-1 rounded text-sm min-w-[16rem]"
            />
            <button
                type="button"
                disabled={!reason.trim() || isPending}
                onClick={handleSubmit}
                className="bg-red-600 text-white px-3 py-1 rounded hover:bg-red-700 disabled:bg-gray-400 text-sm"
            >
                {t('invoice.void')}
            </button>
            <button type="button" onClick={() => setOpen(false)} className="text-gray-600 hover:underline text-sm">
                {t('common.cancel')}
            </button>
        </span>
    )
}
