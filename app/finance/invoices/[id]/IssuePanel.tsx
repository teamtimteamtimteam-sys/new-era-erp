'use client'

// INV-2b:发票的预览 / 签发。形状取自报价那一份(它取自销售订单,后者取自采购单)。
//
// 【预览与签发是两件事】预览按【当前】数据渲染,看完就没了、不落档;签发把那一刻的
// 字节存进桶里并记一版 —— 客户手里那份是某个具体版本。这句话在标题旁边也说了一遍,
// 因为这一页上"预览"与"签发"两个按钮挨着,而它们的后果差着一个档案。
//
// 【这是这一族的第四份复制,而它是刻意的】po / so / quote / cn 各有一份近乎一样的
// 面板(采购单那份甚至不是组件,是个 <form method="post">),shipment 连详情页都没有。
// 抽成 app/components/ 的公共件是【一次单独的刀】,要一次把它们全迁过去、并且逐个
// 手工确认入口(全是 [id] 路由,可达性走查看不见它们)—— 不要顺手在别的刀里抽,
// 那会让一次渲染层的改动悄悄动到四个在用的页面。已记在 docs/known-issues.md。
//
// 【kind 与签发无关】sale 与 order 两种发票走同一个 record_invoice_issue:它们的
// 区别在【怎么产生应收】,而"这一版发出去了"与那个区别毫无关系 —— 客户手里拿到的
// 都是一张纸。所以这个面板不看 kind。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'

export default function IssuePanel({
    invoiceId, canIssue, blockedReason, hasLines,
}: {
    invoiceId: string; canIssue: boolean; blockedReason: string; hasLines: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const blocked = !canIssue || !hasLines

    function issue() {
        setError('')
        startTransition(async () => {
            const res = await fetch(`/finance/invoices/${invoiceId}/pdf`, { method: 'POST' })
            // 【服务端拒了就把服务端那句话原样显示】路由已经按名翻译过
            //(localizeInvoiceError),所以这里拿到的是人话,不是 INV_NO_LINES。
            if (!res.ok) { setError(await res.text()); return }
            router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3 mb-2">
            <a href={`/finance/invoices/${invoiceId}/pdf`} target="_blank" rel="noopener noreferrer"
               className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                {t('invoice.previewPdf')}
            </a>
            <button type="button" onClick={issue} disabled={isPending || blocked}
                    className="text-sm border border-gray-400 px-3 py-1 rounded hover:bg-gray-50 disabled:opacity-50">
                {isPending ? t('common.saving') : t('invoice.issuePdf')}
            </button>
            {/* 【禁用了就把理由摆在旁边】一个按不下去、又不说为什么的按钮,读起来
                像是坏了(CMP-2)。作废的发票走的正是这一支,文案就是引擎那条
                INV_VOIDED_NOT_ISSUABLE 说的同一件事。 */}
            {blockedReason && <span className="text-xs text-amber-700">{blockedReason}</span>}
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
