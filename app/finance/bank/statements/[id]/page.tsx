// app/finance/bank/statements/[id]/page.tsx
// 对账单详情(本切只读):头部卡 + 导入提示横幅(?overlap= / ?dups=)+ 行表
// (金额右对齐,负数标红,状态 pill,忽略理由)+ 页脚合计与 期初 + Σ = 期末 校验行。
// 逐笔匹配在 3c 落地;open 状态下可软删(坏导入丢弃)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import Subnav from '../../../Subnav'
import DeleteStatementButton from './DeleteStatementButton'

export default async function BankStatementDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ overlap?: string; dups?: string }>
}) {
    const { id } = await params
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: stmt, error } = await supabase
        .from('bank_statements')
        .select('id, code, bank_account_code, currency, period_start, period_end, opening_balance, closing_balance, file_name, status, reconciled_at, notes')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !stmt) {
        notFound()
    }

    const { data: lines } = await supabase
        .from('bank_statement_lines')
        .select('id, line_no, line_date, description, reference, amount, match_status, ignore_reason')
        .eq('statement_id', id)
        .order('line_no', { ascending: true })

    const rows = lines ?? []
    const sum = Math.round(rows.reduce((s, r) => s + r.amount, 0) * 100) / 100
    const computed = Math.round((stmt.opening_balance + sum) * 100) / 100
    const balanced = Math.round((computed - stmt.closing_balance) * 100) === 0

    const overlap = Number(sp.overlap) || 0
    const dups = Number(sp.dups) || 0

    return (
        <div className="p-8 max-w-6xl">
            <div className="mb-6">
                <Link href="/finance/bank/statements" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('bank.detailTitle')}</h1>

            <Subnav />

            {/* 导入提示(信息,不是错误)*/}
            {(overlap > 0 || dups > 0) && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm space-y-1">
                    {overlap > 0 && <p>{t('bank.warnOverlap', { n: overlap })}</p>}
                    {dups > 0 && <p>{t('bank.warnDuplicates', { n: dups })}</p>}
                </div>
            )}

            {/* 头部卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('bank.colCode')}:</span>
                    <span className="font-mono font-medium">{stmt.code}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('bank.colAccount')}:</span>
                    <span className="font-mono">{stmt.bank_account_code}</span>{' '}
                    {t('finance.bank.' + stmt.bank_account_code)}
                    <span className="text-gray-500 ml-2">{stmt.currency}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('bank.colPeriod')}:</span>
                    <span>
                        {stmt.period_start} – {stmt.period_end}
                    </span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('bank.colOpening')}:</span>
                    <span className="font-mono">{formatAmount(stmt.opening_balance, stmt.currency)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('bank.colClosing')}:</span>
                    <span className="font-mono font-medium">{formatAmount(stmt.closing_balance, stmt.currency)}</span>
                </div>
                {stmt.file_name && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('bank.fileName')}:</span>
                        <span className="font-mono text-xs">{stmt.file_name}</span>
                    </div>
                )}
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (stmt.status === 'reconciled'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {t('bank.status.' + stmt.status)}
                    </span>
                </div>
                {stmt.reconciled_at && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('bank.reconciledAt')}:</span>
                        <span>{new Date(stmt.reconciled_at).toLocaleString(dateLocale)}</span>
                    </div>
                )}
                {stmt.status === 'open' && <DeleteStatementButton statementId={stmt.id} />}
            </div>

            {stmt.notes && (
                <p className="text-sm text-gray-600 mb-4 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {stmt.notes}
                </p>
            )}

            {/* 行表 */}
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colLineNo')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colDate')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colDescription')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.colReference')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('bank.colAmount')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('finance.colStatus')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('bank.ignoreReason')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-3 py-1 text-sm text-gray-500">{r.line_no}</td>
                            <td className="border border-gray-300 px-3 py-1 text-sm">{r.line_date}</td>
                            <td className="border border-gray-300 px-3 py-1 text-sm">{r.description ?? '—'}</td>
                            <td className="border border-gray-300 px-3 py-1 text-sm font-mono">{r.reference ?? '—'}</td>
                            <td
                                className={
                                    'border border-gray-300 px-3 py-1 text-right font-mono text-sm ' +
                                    (r.amount < 0 ? 'text-red-600' : '')
                                }
                            >
                                {formatAmount(r.amount, null)}
                            </td>
                            <td className="border border-gray-300 px-3 py-1">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (r.match_status === 'matched'
                                            ? 'bg-green-100 text-green-800'
                                            : r.match_status === 'ignored'
                                              ? 'bg-gray-200 text-gray-600'
                                              : 'bg-amber-100 text-amber-800')
                                    }
                                >
                                    {t('bank.lineStatus.' + r.match_status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-3 py-1 text-sm text-gray-600">
                                {r.ignore_reason ?? '—'}
                            </td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('bank.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
                {rows.length > 0 && (
                    <tfoot>
                        <tr className="bg-gray-100 font-bold">
                            <td className="border border-gray-300 px-3 py-2 text-sm" colSpan={4}>
                                {t('bank.colLines')}: {rows.length}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatAmount(sum, null)}
                            </td>
                            <td className="border border-gray-300 px-3 py-2" colSpan={2} />
                        </tr>
                    </tfoot>
                )}
            </table>

            {/* 期初 + Σ = 期末 校验行 */}
            <p className={'text-sm mt-3 ' + (balanced ? 'text-green-700' : 'text-red-600')}>
                {balanced
                    ? `✓ ${t('bank.balanceOk')}`
                    : `✗ ${t('bank.balanceMismatch', {
                          computed: formatAmount(computed, stmt.currency),
                          entered: formatAmount(stmt.closing_balance, stmt.currency),
                          delta: formatAmount(Math.round((computed - stmt.closing_balance) * 100) / 100, stmt.currency),
                      })}`}
            </p>

            <p className="text-sm text-gray-500 mt-4">{t('bank.matchingNextCut')}</p>
        </div>
    )
}
