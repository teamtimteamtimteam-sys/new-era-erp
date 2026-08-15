'use client'

// CN-1:贷项凭证的预览 / 签发。形状取自销售订单那一份。
// 【预览与签发是两件事】预览按【当前】数据渲染,不落档;签发把那一刻的字节
// 存进桶里并记一版 —— 客户手里那份是某个具体版本。
// 【这里没有"草稿不给签发"那一支】凭证一出生就已经过账了(先过账再写单头),
// 不存在"还不是承诺"的中间态 —— 与销售订单刻意不同,所以按钮没有禁用分支。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function IssuePanel({ noteId }: { noteId: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')

    function issue() {
        setError('')
        startTransition(async () => {
            const res = await fetch(`/finance/credit-notes/${noteId}/pdf`, { method: 'POST' })
            if (!res.ok) { setError(await res.text()); return }
            router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3 mb-2">
            <a href={`/finance/credit-notes/${noteId}/pdf`} target="_blank" rel="noopener noreferrer"
               className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                {t('cn.previewPdf')}
            </a>
            <button type="button" onClick={issue} disabled={isPending}
                    className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                {isPending ? t('common.saving') : t('cn.issuePdf')}
            </button>
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
