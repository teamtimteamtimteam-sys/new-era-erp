// app/finance/bank/page.tsx
// 银行对账首页:每个银行账户一张卡(账面余额 / 最近对账单 / 差额 / 两侧未匹配计数),
// 卡片下方列出该账户的待对账报表并直链工作台 —— 这是每月对账的入口。
// 金额一律用 formatAmount 带币种 —— SGD 账户的数字绝不能被当成 USD 展示。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import TransferForm from './TransferForm'
import Subnav from '../Subnav'

// 视图列生成类型全可空;取用列本地锁死
type StatusRow = {
    account_code: string
    currency: string | null
    ledger_balance: number
    latest_statement_code: string | null
    latest_statement_period_end: string | null
    latest_closing_balance: number | null
    unmatched_statement_lines: number
    ignored_statement_lines: number
    unmatched_journal_lines: number
    unmatched_journal_amount: number
    difference: number | null
}

export default async function BankHomePage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('bank_reconciliation_status')
        .select('*')
        .order('account_code')

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('bank.title')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = (data as unknown as StatusRow[] | null) ?? []

    // 待对账(open)报表 + 每张的未处理行数 —— 卡片下方直链工作台
    const { data: openStatements } = await supabase
        .from('bank_statements')
        .select('id, code, bank_account_code, period_end')
        .eq('status', 'open')
        .is('deleted_at', null)
        .order('period_end', { ascending: false })

    const openIds = (openStatements ?? []).map((s) => s.id)
    const { data: openLines } = openIds.length
        ? await supabase
              .from('bank_statement_lines')
              .select('statement_id, match_status')
              .in('statement_id', openIds)
              .eq('match_status', 'unmatched')
        : { data: [] as { statement_id: string; match_status: string }[] }

    const outstandingById = new Map<string, number>()
    for (const l of openLines ?? []) {
        outstandingById.set(l.statement_id, (outstandingById.get(l.statement_id) ?? 0) + 1)
    }

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('bank.title')}</h1>
                <div className="flex gap-3">
                    <Link
                        href="/finance/bank/statements"
                        className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50"
                    >
                        {t('bank.statements')}
                    </Link>
                    <Link
                        href="/finance/bank/import"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('bank.import')}
                    </Link>
                </div>
            </div>

            <Subnav />

            <TransferForm />

            <div className="grid gap-4 md:grid-cols-2 mb-6">
                {rows.map((r) => (
                    <div key={r.account_code} className="border border-gray-300 rounded p-4">
                        <h2 className="font-bold mb-3">
                            <span className="font-mono">{r.account_code}</span>{' '}
                            {t('finance.bank.' + r.account_code)}
                            <span className="ml-2 text-sm text-gray-500">{r.currency}</span>
                        </h2>

                        <dl className="text-sm space-y-1">
                            <div className="flex justify-between">
                                <dt className="text-gray-600">{t('bank.ledgerBalance')}</dt>
                                <dd className="font-mono">{formatAmount(r.ledger_balance, r.currency)}</dd>
                            </div>
                            <div className="flex justify-between">
                                <dt className="text-gray-600">{t('bank.latestStatement')}</dt>
                                <dd className="font-mono">
                                    {r.latest_statement_code ? (
                                        <>
                                            {r.latest_statement_code}
                                            <span className="text-gray-500 ml-2">
                                                {r.latest_statement_period_end}
                                            </span>
                                        </>
                                    ) : (
                                        <span className="text-gray-500 font-sans">{t('bank.noStatement')}</span>
                                    )}
                                </dd>
                            </div>
                            <div className="flex justify-between">
                                <dt className="text-gray-600">{t('bank.closingBalance')}</dt>
                                <dd className="font-mono">
                                    {r.latest_closing_balance === null
                                        ? '—'
                                        : formatAmount(r.latest_closing_balance, r.currency)}
                                </dd>
                            </div>
                            <div className="flex justify-between border-t pt-1 mt-1">
                                <dt className="text-gray-600">{t('bank.difference')}</dt>
                                <dd
                                    className={
                                        'font-mono font-bold ' +
                                        (r.difference !== null && Math.round(r.difference * 100) !== 0
                                            ? 'text-red-600'
                                            : '')
                                    }
                                >
                                    {r.difference === null ? '—' : formatAmount(r.difference, r.currency)}
                                </dd>
                            </div>
                            <div className="flex justify-between">
                                <dt className="text-gray-600">{t('bank.unmatchedStatementLines')}</dt>
                                <dd className="font-mono">{r.unmatched_statement_lines}</dd>
                            </div>
                            <div className="flex justify-between">
                                <dt className="text-gray-600">{t('bank.unmatchedJournalLines')}</dt>
                                <dd className="font-mono">
                                    {r.unmatched_journal_lines}
                                    <span className="text-gray-500 ml-2">
                                        {formatAmount(r.unmatched_journal_amount, r.currency)}
                                    </span>
                                </dd>
                            </div>
                        </dl>

                        {/* 待对账报表:直链工作台(每月对账的入口)*/}
                        {(openStatements ?? []).filter((s) => s.bank_account_code === r.account_code)
                            .length > 0 && (
                            <div className="mt-3 pt-3 border-t">
                                <p className="text-xs font-medium text-gray-600 mb-1">
                                    {t('bank.openStatements')}
                                </p>
                                <ul className="text-sm space-y-1">
                                    {(openStatements ?? [])
                                        .filter((s) => s.bank_account_code === r.account_code)
                                        .map((s) => (
                                            <li key={s.id} className="flex justify-between gap-3">
                                                <Link
                                                    href={`/finance/bank/statements/${s.id}/reconcile`}
                                                    className="text-blue-600 hover:underline font-mono"
                                                >
                                                    {s.code}
                                                </Link>
                                                <span className="text-gray-500">
                                                    {s.period_end} ·{' '}
                                                    {t('bank.outstandingCount', {
                                                        n: outstandingById.get(s.id) ?? 0,
                                                    })}
                                                </span>
                                            </li>
                                        ))}
                                </ul>
                            </div>
                        )}
                    </div>
                ))}
            </div>

            <p className="text-sm text-gray-500 max-w-3xl">{t('bank.identityNote')}</p>
        </div>
    )
}
