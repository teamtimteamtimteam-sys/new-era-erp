'use client'

// SO-4b:报价的预览 / 签发。形状取自销售订单那一份。
// 【预览与签发是两件事】预览按【当前】数据渲染,不落档;签发把那一刻的字节
// 存进桶里并记一版 —— 客户手里那份是某个具体版本。
//
// 【第一次签发就是 draft → issued 那次转换】所以这个按钮同时是状态转换的入口,
// 与订单刻意不同(订单的签发不动状态)。
//
// 【一张没有行的报价不给签发 —— 而这是【界面比数据库严】的一处,写下来】
// record_qt_issue 今天不查行数,于是签发一张空报价在服务端是通的;发给客户的
// 却会是一张没有任何内容的纸。这里先把钮禁掉并说出原因 —— 见切次报告里
// 点名的那处缺口(它该由引擎拥有,但那是一次规则变更,不是这一刀顺手做的事)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function IssuePanel({
    quoteId, canIssue, blockedReason, hasLines,
}: {
    quoteId: string; canIssue: boolean; blockedReason: string; hasLines: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const blocked = !canIssue || !hasLines

    function issue() {
        setError('')
        startTransition(async () => {
            const res = await fetch(`/sales/quotes/${quoteId}/pdf`, { method: 'POST' })
            if (!res.ok) { setError(await res.text()); return }
            router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3 mb-2">
            <a href={`/sales/quotes/${quoteId}/pdf`} target="_blank" rel="noopener noreferrer"
               className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                {t('quotes.previewPdf')}
            </a>
            <button type="button" onClick={issue} disabled={isPending || blocked}
                    className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                {isPending ? t('common.saving') : t('quotes.issuePdf')}
            </button>
            {blockedReason && <span className="text-xs text-amber-700">{blockedReason}</span>}
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
