'use client'

// 作废发票:内联理由输入 + window.confirm,再调 voidInvoice。
// 理由必填(DB 侧 REASON_REQUIRED 兜底);成功后 revalidate 让页面切到已作废状态。
import { useState, useTransition } from 'react'
import { voidInvoice } from './actions'
import { useTranslations } from '@/lib/i18n/client'

// SO-3a:order 头的作废是一次【冲销】(借 2500 / 贷 1100)—— 冲销日必填,
// 它决定冲销分录落进哪个期间,永不默认(与手工冲销分录同一条);sale 头照旧。
export default function VoidInvoiceControl({ invoiceId, kind = 'sale' }: { invoiceId: string; kind?: string }) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [open, setOpen] = useState(false)
    const [reason, setReason] = useState('')
    const [reversalDate, setReversalDate] = useState('')
    const isOrder = kind === 'order'

    function handleSubmit() {
        if (!window.confirm(t('invoice.voidConfirm'))) return
        startTransition(async () => {
            const result = await voidInvoice(invoiceId, reason.trim(), isOrder ? reversalDate : undefined)
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
            {isOrder && (
                <span className="flex items-center gap-1">
                    <input
                        type="date"
                        value={reversalDate}
                        onChange={(e) => setReversalDate(e.target.value)}
                        className="border border-gray-300 px-3 py-1 rounded text-sm"
                        title={t('invoice.voidReversalDateWhy')}
                    />
                    <span className="text-xs text-gray-500">{t('invoice.voidReversalDateWhy')}</span>
                </span>
            )}
            <button
                type="button"
                disabled={!reason.trim() || (isOrder && !reversalDate.trim()) || isPending}
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
