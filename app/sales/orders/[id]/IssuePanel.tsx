'use client'

// SO-1:预览 / 签发。
// 【预览与签发是两件事】预览按【当前】数据渲染,不落档;签发把那一刻的字节
// 存进桶里并记一版 —— 客户手里那份是某个具体版本。
// 【草稿不给签发】record_so_issue 会按名拒(SO_NOT_ISSUABLE),这里顺带把按钮
// 也禁掉:一个必然被拒的按钮不该画出来(AGENTS.md 那条"页面与服务端一致")。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function IssuePanel({ orderId, status }: { orderId: string; status: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const isDraft = status === 'draft'

    function issue() {
        setError('')
        startTransition(async () => {
            const res = await fetch(`/sales/orders/${orderId}/pdf`, { method: 'POST' })
            if (!res.ok) { setError(await res.text()); return }
            router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3 mb-2">
            <a href={`/sales/orders/${orderId}/pdf`} target="_blank" rel="noopener noreferrer"
               className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                {t('sales.previewPdf')}
            </a>
            <button type="button" onClick={issue} disabled={isPending || isDraft}
                    className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                {isPending ? t('common.saving') : t('sales.issuePdf')}
            </button>
            {isDraft && <span className="text-xs text-amber-700">{t('sales.issueBlockedDraft')}</span>}
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
