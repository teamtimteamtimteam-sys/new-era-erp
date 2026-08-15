// app/finance/credit-notes/[id]/page.tsx
// CN-1:贷项凭证详情 —— 它冲的是哪一张发票、每一行是哪一种、过了哪一笔账、签发档。
//
// 【这一页刻意没有任何编辑控件】凭证只增不改(CREDIT_NOTE_IMMUTABLE):它是
// 一份已经过账、而且可能已经寄出去的单据。写错了要冲销 —— 而冲销一张贷项凭证
// 需要"负数金额"或"反向类型",两者都要先回答"客户贷余放在哪"这个还没有答案的
// 问题(见 CN-1 迁移抬头的停放清单)。所以这里连一个注定被拒的按钮都不摆。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import IssuePanel from './IssuePanel'

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
        await supabase.from('customers').select('code, legal_name')
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

    return (
        <>
            <Subnav />
            <div className="p-8 max-w-4xl">
                <div className="mb-6">
                    <Link href={inv ? `/finance/invoices/${inv.id}` : '/finance/invoices'}
                          className="text-blue-600 hover:underline text-sm">{t('common.back')}</Link>
                </div>
                <div className="flex items-start justify-between mb-4">
                    <div>
                        <h1 className="text-2xl font-bold font-mono">{cn.code}</h1>
                        <p className="text-sm text-gray-600 mt-1">
                            {customer ? `${customer.code} — ${customer.legal_name}` : '—'}
                        </p>
                    </div>
                    <span className="px-3 py-1 rounded bg-gray-200 text-sm">{t('cn.badge')}</span>
                </div>

                <dl className="grid grid-cols-2 gap-x-8 gap-y-1 text-sm mb-6">
                    <div><dt className="inline text-gray-500">{t('cn.noteDate')}: </dt>
                         <dd className="inline">{new Date(cn.note_date).toLocaleDateString(dl)}</dd></div>
                    {/* 【它冲的是哪一张发票】—— 这一页最要紧的一个链接 */}
                    <div><dt className="inline text-gray-500">{t('cn.againstInvoice')}: </dt>
                         <dd className="inline">
                             {inv ? (
                                 <Link href={`/finance/invoices/${inv.id}`}
                                       className="font-mono text-blue-600 hover:underline">{inv.code}</Link>
                             ) : '—'}
                         </dd></div>
                    <div><dt className="inline text-gray-500">{t('sales.colCurrency')}: </dt>
                         <dd className="inline">{cn.currency} @ {cn.fx_rate}</dd></div>
                    <div><dt className="inline text-gray-500">{t('cn.journal')}: </dt>
                         <dd className="inline">
                             {entry ? (
                                 <Link href={`/finance/journal/${entry.id}`}
                                       className="font-mono text-blue-600 hover:underline">{entry.code}</Link>
                             ) : '—'}
                         </dd></div>
                    <div className="col-span-2"><dt className="inline text-gray-500">{t('cn.reason')}: </dt>
                         <dd className="inline">{cn.reason}</dd></div>
                </dl>

                {/* 【汇率那一句要说出来】凭证按【发票存下来的】汇率冲,不是今天的行情 ——
                    否则单据币种归零之后本位币还会剩一截,而那截与真实的已实现汇兑
                    在账上长得一模一样,却没有任何钱动过。 */}
                <p className="text-xs text-gray-500 mb-6">{t('cn.rateNote', { code: inv?.code ?? '—' })}</p>

                <h2 className="font-medium mb-2">{t('cn.linesTitle')}</h2>
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">#</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cn.colLine')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cn.colKind')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('cn.colQty')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">
                                {t('cn.colAmount', { ccy: cn.currency })}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {lines.map((l) => (
                            <tr key={l.id}>
                                <td className="border border-gray-300 px-3 py-2">
                                    {byId.get(l.invoice_line_id)?.line_no ?? '—'}
                                </td>
                                <td className="border border-gray-300 px-3 py-2">
                                    {byId.get(l.invoice_line_id)?.description ?? '—'}
                                </td>
                                {/* 动态前缀,后缀集合接 credit_note_lines 的 CHECK(check-i18n 的清单) */}
                                <td className="border border-gray-300 px-3 py-2">{t('cn.kind.' + l.kind)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {l.qty === null ? '—' : l.qty}{' '}
                                    {l.qty === null ? '' : (byId.get(l.invoice_line_id)?.unit ?? '')}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    −{formatMoneyBare(Number(l.amount), '同表列头 冲减({ccy})')}
                                </td>
                            </tr>
                        ))}
                        <tr className="bg-gray-50 font-medium">
                            <td className="border border-gray-300 px-3 py-2" colSpan={4}>{t('cn.totalLabel')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                −{formatAmount(total, cn.currency)}
                            </td>
                        </tr>
                    </tbody>
                </table>

                <h2 className="font-medium mt-8 mb-2">{t('cn.issues')}</h2>
                <IssuePanel noteId={cn.id} />
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
            </div>
        </>
    )
}
