'use client'

// app/customers/StatementPanel.tsx
// STATEMENT-1:客户档案页上的【对账单】那一段 —— 这条路唯一的入口。
//
// ★【为什么在这里,而不是另起一张财务页】★
// 客户状况页(SAL-B6)本来就是"这个客户的财务仓位"那一屏:身份、信用限额、
// 敞口、未结明细。对账单就是那个仓位【寄出去的样子】,所以它属于这一页。
// 另起一张页要新的导航入口、新的可达性、还要把客户上下文再拼一遍。
//
// 【先预览,后签发 —— 而两者读的是同一支函数】签发之前先把数算出来摆在屏幕上,
// 人看过再决定要不要冻。预览走 customer_statement_data,签发走
// issue_customer_statement 而它内部也调 customer_statement_data ——
// 一份实现,两个调用方(fixture 137 的 H 臂用目录断言钉住这件事)。
//
// 【默认上个自然月】催收找的往往是"上个月"这个窗口;而 from/to 可改,
// 因为催收也会找"上次说过话之后"这种不规则区间。
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { previewStatement, issueStatement } from './statementActions'
import { useTranslations } from '@/lib/i18n/client'

type Preview = {
    opening_base: number; charges_base: number; credits_base: number
    receipts_base: number; applied_base: number; on_account_base: number
    net_due_base: number; closing_base: number
    ties: boolean; tie_difference: number; no_movement: boolean
    base_currency: string
    lines: { doc_code: string }[]
}

type Issued = {
    id: string; code: string; period_start: string; period_end: string
    closing_base: number; issued_at: string; superseded_at: string | null
}

function lastMonth(): { from: string; to: string } {
    const now = new Date()
    const end = new Date(now.getFullYear(), now.getMonth(), 0)
    const start = new Date(end.getFullYear(), end.getMonth(), 1)
    const iso = (d: Date) =>
        `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
    return { from: iso(start), to: iso(end) }
}

const money = (n: number) =>
    n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

export default function StatementPanel({
    customerId,
    issued,
    canIssue,
}: {
    customerId: string
    issued: Issued[]
    canIssue: boolean
}) {
    const t = useTranslations()
    const d = lastMonth()
    const [from, setFrom] = useState(d.from)
    const [to, setTo] = useState(d.to)
    const [reason, setReason] = useState('')
    const [preview, setPreview] = useState<Preview | null>(null)
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const run = (fn: () => Promise<{ error?: string }>) => {
        setError(null)
        startTransition(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
        })
    }

    const row = (label: string, value: number, paren = false) => (
        <div className="flex justify-between py-0.5">
            <span className="text-gray-600">{label}</span>
            <span className="font-mono">{paren ? `(${money(value)})` : money(value)}</span>
        </div>
    )

    return (
        <section className="mb-8">
            <h2 className="text-lg font-semibold mb-2">{t('statements.sectionTitle')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('statements.sectionHint')}</p>

            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}

            <div className="flex flex-wrap items-end gap-3 mb-3">
                <label className="text-sm text-gray-600">
                    {t('statements.from')}
                    <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                        className="block rounded border border-gray-300 bg-white px-3 py-2" />
                </label>
                <label className="text-sm text-gray-600">
                    {t('statements.to')}
                    <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
                        className="block rounded border border-gray-300 bg-white px-3 py-2" />
                </label>
                <button type="button" disabled={pending}
                    onClick={() => run(async () => {
                        const r = await previewStatement(customerId, from, to)
                        if (!r.error) setPreview(r.data as Preview)
                        return r
                    })}
                    className="border border-gray-300 rounded px-3 py-2 text-sm hover:bg-gray-50 disabled:opacity-50">
                    {t('statements.preview')}
                </button>
            </div>

            {preview && (
                <div className="mb-4 rounded border border-gray-300 p-3 text-sm max-w-md">
                    <p className="text-xs text-gray-500 mb-2">
                        {t('statements.previewIsLive')}
                    </p>
                    {row(t('statements.doc.opening'), preview.opening_base)}
                    {row(t('statements.doc.charges'), preview.charges_base)}
                    {row(t('statements.doc.credits'), preview.credits_base, true)}
                    {row(t('statements.doc.applied'), preview.applied_base, true)}
                    <div className="flex justify-between border-t border-gray-400 mt-1 pt-1 font-medium">
                        <span>{t('statements.doc.closing')}</span>
                        <span className="font-mono">{money(preview.closing_base)}</span>
                    </div>
                    {preview.on_account_base !== 0 && (
                        <>
                            {row(t('statements.doc.onAccount'), preview.on_account_base, true)}
                            <div className="flex justify-between border-t border-gray-400 mt-1 pt-1 font-medium">
                                <span>{t('statements.doc.netDue')}</span>
                                <span className="font-mono">{money(preview.net_due_base)}</span>
                            </div>
                        </>
                    )}
                    {/* 【期间内没有发生额是一个有名字的状态】—— 不是一张空表 */}
                    {preview.no_movement && (
                        <p className="mt-2 text-xs text-amber-800">{t('statements.doc.noMovement')}</p>
                    )}
                    {/* 对不上时【说出来并且不给签发按钮】—— 服务端也会拒(合取) */}
                    {!preview.ties && (
                        <p className="mt-2 text-xs text-red-700">
                            {t('statements.doesNotTie', { diff: money(preview.tie_difference) })}
                        </p>
                    )}
                </div>
            )}

            {canIssue && preview?.ties && (
                <div className="flex flex-wrap items-end gap-3 mb-4">
                    <label className="text-sm text-gray-600">
                        {t('statements.supersedeReason')}
                        <input value={reason} onChange={(e) => setReason(e.target.value)}
                            placeholder={t('statements.supersedeReasonHint')}
                            className="block rounded border border-gray-300 bg-white px-3 py-2 w-72" />
                    </label>
                    <button type="button" disabled={pending}
                        onClick={() => run(() => issueStatement(customerId, from, to, reason))}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm disabled:opacity-50">
                        {t('statements.issue')}
                    </button>
                </div>
            )}

            <h3 className="text-sm font-semibold mb-1">{t('statements.issuedTitle')}</h3>
            {issued.length === 0 ? (
                // 【命名的缺席,不是空白】"还没有出过"与"读不到"要说得不一样
                <p className="text-sm text-gray-500">{t('statements.noneIssued')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('statements.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('statements.colPeriod')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('statements.doc.closing')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('statements.colIssued')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {issued.map((s) => (
                            <tr key={s.id} className={s.superseded_at ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-3 py-2 font-mono">
                                    <Link href={`/finance/statements/${s.id}/pdf`}
                                        className="text-blue-600 hover:underline">{s.code}</Link>
                                    {s.superseded_at && (
                                        <span className="ml-2 px-1.5 py-0.5 rounded text-[11px] bg-gray-200 text-gray-700">
                                            {t('statements.superseded')}
                                        </span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">
                                    {s.period_start} → {s.period_end}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {money(s.closing_base)}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-xs">
                                    {s.issued_at.slice(0, 10)}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}
