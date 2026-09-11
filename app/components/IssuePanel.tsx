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
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function IssuePanel({
    pdfHref,
    previewLabel,
    issueLabel,
    canIssue = true,
    blockedReason = '',
    hasLines = true,
    nothingToIssueNote = '',
    permission,
}: {
    /** 该单据的 pdf 路由:GET 预览、GET ?version=N 取档、POST 签发。整条路径由
     *  调用页给出 —— 组件不拼路径,拼错一段的代价是一次看起来像"页面坏了"的 404。 */
    pdfHref: string
    /** 预览按钮的文案 —— 每一族有自己的说法(quotes./sales./cn./invoice./purchasing.),
     *  文案留在调用页,所以抽取【不改任何一页的字】。 */
    previewLabel: string
    /** 签发按钮的文案,同上。 */
    issueLabel: string
    /**
     * ★ ALERT-2d(2026-09-09):这个 prop 现在【只装记录状态】,不再装权限。
     * 原注释写的是「状态、权限、已转单、已作废…」—— 六种东西一个布尔,
     * 而 `blockedReason` 只有一个字符串槽。于是 /sales/quotes 那一处
     * **权限那一支根本没有对应的句子**:没有 `module.sales.edit` 的人看到的是
     * 一个禁用的签发钮 + **一片空白**。权限那一半改走下面的 `permission`。
     */
    canIssue?: boolean
    /** 禁用时【摆在旁边的那句话】。一个按不下去、又不说为什么的按钮,读起来像是
     *  坏了(CMP-2)。空串 = 不显示。**这一句现在只说记录状态。** */
    blockedReason?: string
    /** 有没有行。一张没有行的单据不给签发 —— 发出去的会是一张没有内容的纸。
     *  默认 true(不适用这一支的单据不传)。 */
    hasLines?: boolean
    /**
     * ★ ALERT-2d ④(c):【还没有东西可签发】不是一句拒绝。
     *
     * `!hasLines` 既不是权限答复,也不是记录状态 —— 它是"这张单子还是空的"。
     * 给它写一句拒绝的话(琥珀色、和"已作废"同一个位置同一个颜色)会把
     * **一件下一步显而易见的事**说成一堵墙。所以它走这一格,用中性的灰,
     * 说的是【先去加一行】,不是【你不可以】。
     * 空串 = 不显示(这张单据没有"行"这个概念)。
     */
    nothingToIssueNote?: string
    /**
     * ★ ALERT-2d:权限那一半,从 `canIssue` 里拆出来。
     *
     * 传了它,签发钮就走 `<PermissionGate>`:**看得见、按不动、点名那个码,
     * 并说明管理员在 Settings → Roles 里给**(DBLOCK-1 的裁定,与按下去之后
     * SILENT-1 说的是同一句话)。不传 = 这份单据的签发不由某一个权限码决定。
     *
     * 【为什么不闸预览】预览是一次【读】,而且它是一个 <a>;
     * `fieldset disabled` 本来也禁不掉链接。把一次读也挡掉,是把"你改不了"
     * 说成"你看不了" —— 两句不同的话。
     */
    permission?: { code: string; allowed: boolean }
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    // ★ ALERT-2d ④:三样东西,三句话,而它们此前挤在这一个布尔里。
    //   · `!canIssue`   → 记录状态,`blockedReason` 说它(琥珀);
    //   · `!hasLines`   → "还没有东西可签发",`nothingToIssueNote` 说它(中性灰);
    //   · 权限          → 不在这里了,它由外面那层 <PermissionGate> 说。
    //   ★【权限那一半【不进这个布尔】,而这不是风格问题】★
    //     `<PermissionGate>` 用的是 `<fieldset disabled>`,它已经把里面的按钮
    //     置成 disabled 了 —— 再在这里 `|| !permission.allowed` 是把同一件事
    //     做两遍。两份实现,而它们只在写下来那天一致(本仓库为这个形状付过四次账)。
    //     所以这里只留【不是权限】的那两个:一个原因一处机制,一处机制一句话。
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
            <Button asChild variant="outline">
                <a href={pdfHref} target="_blank" rel="noopener noreferrer">
                    {previewLabel}
                </a>
            </Button>
            {/* ★ 瞬态那一半留在 disabled 里(`isPending` 一秒后自己消失,而 CMP-2
                   只要求【非瞬态】条件配一行常驻的解释);它已经在按钮的字上说了
                   ——「保存中…」。非瞬态那两半各自有自己的句子,在下面。 */}
            {(() => {
                const btn = (
                    <Button variant="secondary" className="text-sm" type="button" onClick={issue}
                            disabled={isPending || blocked}>
                        {isPending ? t('common.saving') : issueLabel}
                    </Button>
                )
                return permission ? (
                    <PermissionGate code={permission.code} allowed={permission.allowed} inline>
                        {btn}
                    </PermissionGate>
                ) : (
                    btn
                )
            })()}
            {blockedReason && <span className="text-xs text-amber-700">{blockedReason}</span>}
            {!hasLines && nothingToIssueNote && (
                <span className="text-xs text-[color:var(--brand-muted-text)]" data-state-note="nothing-to-issue">{nothingToIssueNote}</span>
            )}
            {error && <span className="text-xs text-red-600">{error}</span>}
        </div>
    )
}
