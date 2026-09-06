'use client'

// app/components/IssuePanel.tsx
// 【签发这一族的那一块面板 —— 一份实现,六个单据】(EXT-1)
//
// 采购单 / 销售订单 / 报价 / 贷项凭证 / 发票 各有过一份近乎一样的复制,发货单
// 连详情页都没有。四份的真正分歧【只有禁用理由那一支】:销售订单把 isDraft 写死
// 在组件里,贷项凭证压根没有这一支,报价与发票把它作为两个入参传进来 —— 其余
// 逐字相同。采购单那一份甚至不是组件,是个 <form method="post">。
//
// 形状取自【报价那一份】,因为它是表达力最强的那个:(canIssue, blockedReason,
// hasLines) 能把另外三种都表示出来,反过来不行。
//   * 销售订单:canIssue={!isDraft},blockedReason={isDraft ? … : ''}
//   * 贷项凭证 / 采购单:两个都不传 —— 默认永不禁用,与它们此前逐字相同
//
// ── 预览与签发是两件事 ────────────────────────────────────────────────────
// 预览按【当前】数据渲染,看完就没了、不落档;签发把那一刻的字节存进桶里并记一版
// —— 客户/供应商手里那份是某个具体版本。两个按钮挨着,而它们的后果差着一个档案。
//
// ── 【为什么有一支"响应是 PDF 就下载"的分支】───────────────────────────────
// 五条 POST 路由里有【四条返回 JSON】(签发档的元数据),而【采购单那条返回 PDF
// 字节本身】(Content-Disposition: attachment)—— 那是它此前用 <form method="post">
// 的直接后果:表单提交是一次导航,浏览器就把那次响应当成下载。
// 迁到 fetch 之后若只做 router.refresh(),采购单【签发即下载】这个行为就没了。
// 所以这里按响应的 Content-Type 分叉:是 PDF 就存成文件再刷新,不是就只刷新。
// 对另外四条这一支永远不触发。
// 【不改那条路由去迁就组件】——"渲染层的一刀不改单据引擎"是这次的边界;
// 把它改成返回 JSON 会安静地拿掉一个在用的行为。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'

export default function IssuePanel({
    pdfHref,
    previewLabel,
    issueLabel,
    canIssue = true,
    blockedReason = '',
    hasLines = true,
}: {
    /** 该单据的 pdf 路由:GET 预览、GET ?version=N 取档、POST 签发。整条路径由
     *  调用页给出 —— 组件不拼路径,拼错一段的代价是一次看起来像"页面坏了"的 404。 */
    pdfHref: string
    /** 预览按钮的文案 —— 每一族有自己的说法(quotes./sales./cn./invoice./purchasing.),
     *  文案留在调用页,所以抽取【不改任何一页的字】。 */
    previewLabel: string
    /** 签发按钮的文案,同上。 */
    issueLabel: string
    /** 业务上允不允许签发(状态、权限、已转单、已作废…)。默认 true。 */
    canIssue?: boolean
    /** 禁用时【摆在旁边的那句话】。一个按不下去、又不说为什么的按钮,读起来像是
     *  坏了(CMP-2)。空串 = 不显示。 */
    blockedReason?: string
    /** 有没有行。一张没有行的单据不给签发 —— 发出去的会是一张没有内容的纸。
     *  默认 true(不适用这一支的单据不传)。 */
    hasLines?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const blocked = !canIssue || !hasLines

    function issue() {
        setError('')
        startTransition(async () => {
            const res = await fetch(pdfHref, { method: 'POST' })
            // 【服务端拒了就把服务端那句话原样显示】四条路由已经按名翻译过
            // (localize*Error),所以拿到的是人话。采购单那条【还没有】——
            // 它回的是引擎的原文,与它此前把同一句话整页显示出来相比只是位置变了,
            // 不是这一刀新造的问题。见 docs/machine-text-reaching-humans.md。
            if (!res.ok) { setError(await res.text()); return }
            // 见抬头:采购单那条 POST 回的是 PDF 本身,签发即下载。
            if ((res.headers.get('content-type') ?? '').includes('application/pdf')) {
                const blob = await res.blob()
                const url = URL.createObjectURL(blob)
                const a = document.createElement('a')
                a.href = url
                // 文件名取自服务端的 Content-Disposition(它带着单号与版本号);
                // 取不到就退回一个中性的名字,而不是编一个像是真的的。
                const cd = res.headers.get('content-disposition') ?? ''
                const m = /filename\*?=(?:UTF-8''|")?([^";]+)/i.exec(cd)
                a.download = m ? decodeURIComponent(m[1]) : 'document.pdf'
                document.body.appendChild(a)
                a.click()
                a.remove()
                URL.revokeObjectURL(url)
            }
            router.refresh()
        })
    }

    return (
        <div className="flex flex-wrap items-center gap-3 mb-2">
            <a href={pdfHref} target="_blank" rel="noopener noreferrer"
               className="text-sm border border-gray-300 px-3 py-1 rounded hover:bg-gray-50">
                {previewLabel}
            </a>
            <Button variant="secondary" size="sm" className="text-sm" type="button" onClick={issue} disabled={isPending || blocked}>
                {isPending ? t('common.saving') : issueLabel}
            </Button>
            {blockedReason && <span className="text-xs text-amber-700">{blockedReason}</span>}
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
