// app/finance/credit-notes/[id]/page.tsx
// CN-1:贷项凭证详情 —— 它冲的是哪一张发票、每一行是哪一种、过了哪一笔账、签发档。
//
// 【这一页刻意没有任何编辑控件】凭证只增不改(CREDIT_NOTE_IMMUTABLE):它是
// 一份已经过账、而且可能已经寄出去的单据。写错了要冲销 —— 而冲销一张贷项凭证
// 需要"负数金额"或"反向类型",两者都要先回答"客户贷余放在哪"这个还没有答案的
// 问题(见 CN-1 迁移抬头的停放清单)。所以这里连一个注定被拒的按钮都不摆。
//
// ★ CONV-9(2026-09-04):转成 ListPage + RecordHeader + DataTable。
//   模板与三条判据见 docs/detail-page-template.md。
//   【出口检查】这一页唯一的出口是 IssuePanel(签发/预览 PDF),它住在 children 里;
//   而详情页 `state` 恒为 'ok'(记录在不在由 notFound() 回答),所以那个分支
//   永远不成立,签发钮不可能被空态吃掉 —— 逐页做过这项检查,见模板 §⑤。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import IssuePanel from '@/app/components/IssuePanel'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import CreditNoteLinesTable, { type CreditNoteLineRow } from './CreditNoteLinesTable'

export default async function CreditNotePage({ params }: { params: Promise<{ id: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { id } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const cn = mustOne(
        await supabase.from('credit_notes')
            .select('id, code, note_date, reason, currency, fx_rate, invoice_id, entry_id, created_at')
            .eq('id', id).maybeSingle(),
        'credit_notes') as {
            id: string; code: string; note_date: string; reason: string
            currency: string; fx_rate: number; invoice_id: string
            entry_id: string; created_at: string } | null
    if (!cn) notFound()

    const inv = mustOne(
        await supabase.from('invoices_masked')
            .select('id, code, issue_date, customer_id, currency')
            .eq('id', cn.invoice_id).maybeSingle(),
        'invoices') as { id: string; code: string; issue_date: string
                         customer_id: string; currency: string } | null

    const customer = inv ? mustOne(
        await supabase.from('customer_lookup').select('code, legal_name')
            .eq('id', inv.customer_id).maybeSingle(),
        'customers') as { code: string; legal_name: string } | null : null

    const entry = mustOne(
        await supabase.from('journal_entries').select('id, code, entry_date')
            .eq('id', cn.entry_id).maybeSingle(),
        'journal_entries') as { id: string; code: string; entry_date: string } | null

    const lines = mustRows(
        await supabase.from('credit_note_lines')
            .select('id, invoice_line_id, kind, qty, amount')
            .eq('credit_note_id', id).order('created_at'),
        'credit_note_lines') as unknown as {
            id: string; invoice_line_id: string; kind: string
            qty: number | null; amount: number }[]

    const ilIds = [...new Set(lines.map((l) => l.invoice_line_id))]
    const il = ilIds.length === 0 ? [] : (mustRows(
        await supabase.from('invoice_lines_masked')
            .select('id, line_no, description, unit').in('id', ilIds),
        'invoice_lines') as unknown as {
            id: string; line_no: number; description: string; unit: string }[])
    const byId = new Map(il.map((r) => [r.id, r]))

    const issues = mustRows(
        await supabase.from('cn_issues').select('version, file_path, sha256, issued_at')
            .eq('credit_note_id', id).order('version', { ascending: false }),
        'cn_issues') as { version: number; file_path: string; sha256: string; issued_at: string }[]

    const total = Math.round(lines.reduce((s, l) => s + Number(l.amount), 0) * 100) / 100

    // ★【行数据在服务端压平成纯字符串】★ 动态前缀 t('cn.kind.' + …)、单位、
    // 金额格式全部在这里做完 —— 一个 Map、一个判据都不过客户端边界(CONV-1 §①)。
    const amountHeader = t('cn.colAmount', { ccy: cn.currency })
    const tableRows: CreditNoteLineRow[] = lines.map((l) => {
        const src = byId.get(l.invoice_line_id)
        return {
            id: l.id,
            lineNo: src?.line_no != null ? String(src.line_no) : '—',
            description: src?.description ?? '—',
            // 动态前缀,后缀集合接 credit_note_lines 的 CHECK(check-i18n 的清单)
            kindText: t('cn.kind.' + l.kind),
            qtyText: l.qty === null ? '—' : `${l.qty} ${src?.unit ?? ''}`.trim(),
            amountText: `−${formatMoneyBare(Number(l.amount), '同表列头 冲减({ccy})')}`,
        }
    })

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    if (tableRows.length > 0) {
        tableRows.push({
            id: '__total__',
            lineNo: '',
            description: t('cn.totalLabel'),
            kindText: '',
            qtyText: '',
            amountText: `−${formatAmount(total, cn.currency)}`,
            isTotal: true,
        })
    }

    return (
        <ListPage
            maxWidth="max-w-4xl"
            // ★ CONV-8 加的槽:返回链接画在标题【之上】,与转换前同位置。
            breadcrumb={
                <Link href={inv ? `/finance/invoices/${inv.id}` : '/finance/invoices'}
                      className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
            }
            title={<span className="font-mono">{cn.code}</span>}
            // 转换前这枚徽章画在 h1 的右边 —— actions 槽是同一个位置。
            actions={<span className="px-3 py-1 rounded bg-gray-200 text-sm">{t('cn.badge')}</span>}
            intro={customer ? `${customer.code} — ${customer.legal_name}` : '—'}
            // ★★ 详情页恒为 ok —— 记录在不在由上面的 notFound() 回答,不由空态回答。
            //    空的只可能是下面那张行表,那句空态归表自己说(DataTable 的 empty)。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一个 <dl class="grid grid-cols-2">,
                四种抬头写法之一(见 record-header.tsx 抬头的那张表)。 */}
            <RecordHeader
                fields={[
                    { label: t('cn.noteDate'), value: new Date(cn.note_date).toLocaleDateString(dl) },
                    // 【它冲的是哪一张发票】—— 这一页最要紧的一个链接
                    {
                        label: t('cn.againstInvoice'),
                        value: inv ? (
                            <Link href={`/finance/invoices/${inv.id}`}
                                  className="font-mono text-blue-600 hover:underline">{inv.code}</Link>
                        ) : '—',
                    },
                    { label: t('sales.colCurrency'), value: `${cn.currency} @ ${cn.fx_rate}` },
                    {
                        label: t('cn.journal'),
                        value: entry ? (
                            <Link href={`/finance/journal/${entry.id}`}
                                  className="font-mono text-blue-600 hover:underline">{entry.code}</Link>
                        ) : '—',
                    },
                    { label: t('cn.reason'), value: cn.reason },
                ]}
            />

            {/* 【汇率那一句要说出来】凭证按【发票存下来的】汇率冲,不是今天的行情 ——
                否则单据币种归零之后本位币还会剩一截,而那截与真实的已实现汇兑
                在账上长得一模一样,却没有任何钱动过。 */}
            <p className="text-xs text-gray-500 mb-6">{t('cn.rateNote', { code: inv?.code ?? '—' })}</p>

            <h2 className="font-medium mb-2">{t('cn.linesTitle')}</h2>
            <CreditNoteLinesTable rows={tableRows} amountHeader={amountHeader} />

            <h2 className="font-medium mt-8 mb-2">{t('cn.issues')}</h2>
            {/* EXT-1:凭证一出生就已经过账了,不存在"还不是承诺"的中间态 ——
                所以【不传】canIssue / hasLines,按钮永不禁用,与此前逐字相同。 */}
            <IssuePanel
                pdfHref={`/finance/credit-notes/${cn.id}/pdf`}
                previewLabel={t('cn.previewPdf')}
                issueLabel={t('cn.issuePdf')}
            />
            <p className="text-xs text-gray-500 mb-2">{t('cn.issuesNote')}</p>
            {issues.length === 0 ? (
                <p className="text-gray-500 text-sm">{t('cn.noIssues')}</p>
            ) : (
                <ul className="text-sm space-y-1">
                    {issues.map((i) => (
                        <li key={i.version} className="font-mono text-xs">
                            <a href={`/finance/credit-notes/${cn.id}/pdf?version=${i.version}`}
                               target="_blank" rel="noopener noreferrer"
                               className="text-blue-600 hover:underline">v{i.version}</a>
                            {' · '}{new Date(i.issued_at).toLocaleString(dl)} · {i.sha256.slice(0, 12)}…
                        </li>
                    ))}
                </ul>
            )}

            {/* 【为什么这一页没有作废按钮】说出来,而不是留一个空白让人以为漏了 */}
            <p className="text-xs text-gray-500 mt-8">{t('cn.immutableNote')}</p>
        </ListPage>
    )
}
