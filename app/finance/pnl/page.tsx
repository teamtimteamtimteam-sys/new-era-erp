// app/finance/pnl/page.tsx
// 损益表:期间内(from/to,默认本月)revenue/cogs/expense 三类科目的分录聚合。
// 收入 = Σ贷−Σ借,成本/费用 = Σ借−Σ贷;毛利 = 收入−成本(附毛利率),
// 净利 = 毛利−费用(正绿负红)。零发生额科目隐藏。
import { Fragment, Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import PnlToolbar from './PnlToolbar'

// FK 嵌入运行时是对象;显式类型 + cast 锁住
type LineRow = {
    debit: number
    credit: number
    accounts: { code: string; name_en: string; name_zh: string; account_type: string } | null
    journal_entries: { entry_date: string } | null
}

type AccountAgg = {
    code: string
    name_en: string
    name_zh: string
    account_type: string
    debits: number
    credits: number
}

const round2 = (n: number) => Math.round(n * 100) / 100
const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)

export default async function PnlPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    // 默认区间 = 本月;预设:本月 / 上月 / 今年(UTC 口径,与 DB date 同参照)
    const now = new Date()
    const y = now.getUTCFullYear()
    const m = now.getUTCMonth()
    const thisMonth = { from: ymdUtc(new Date(Date.UTC(y, m, 1))), to: ymdUtc(new Date(Date.UTC(y, m + 1, 0))) }
    const lastMonth = { from: ymdUtc(new Date(Date.UTC(y, m - 1, 1))), to: ymdUtc(new Date(Date.UTC(y, m, 0))) }
    const thisYear = { from: `${y}-01-01`, to: `${y}-12-31` }

    const { dateFrom, dateTo } = parseDateRange(sp)
    const from = dateFrom || thisMonth.from
    const to = dateTo || thisMonth.to

    const { data, error } = await supabase
        .from('journal_lines')
        .select('debit, credit, accounts!inner(code, name_en, name_zh, account_type), journal_entries!inner(entry_date)')
        .gte('journal_entries.entry_date', from)
        .lte('journal_entries.entry_date', to)
        .in('accounts.account_type', ['revenue', 'cogs', 'expense'])

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.pnlTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lines = ((data as unknown as LineRow[] | null) ?? []).filter((l) => l.accounts)

    // 按科目聚合
    const agg = new Map<string, AccountAgg>()
    for (const l of lines) {
        const a = l.accounts as NonNullable<LineRow['accounts']>
        let cur = agg.get(a.code)
        if (!cur) {
            cur = { ...a, debits: 0, credits: 0 }
            agg.set(a.code, cur)
        }
        cur.debits += l.debit
        cur.credits += l.credit
    }

    const accountName = (a: AccountAgg) => (locale === 'zh' ? a.name_zh : a.name_en)

    // amount:收入贷正,成本/费用借正;零发生额已被聚合天然排除
    const section = (type: string, creditPositive: boolean) => {
        const rows = Array.from(agg.values())
            .filter((a) => a.account_type === type && (a.debits !== 0 || a.credits !== 0))
            .map((a) => ({
                ...a,
                amount: round2(creditPositive ? a.credits - a.debits : a.debits - a.credits),
            }))
            .sort((a, b) => a.code.localeCompare(b.code))
        const subtotal = round2(rows.reduce((s, r) => s + r.amount, 0))
        return { rows, subtotal }
    }

    const revenue = section('revenue', true)
    const cogs = section('cogs', false)
    const expense = section('expense', false)

    const grossProfit = round2(revenue.subtotal - cogs.subtotal)
    const netProfit = round2(grossProfit - expense.subtotal)
    const marginPct =
        revenue.subtotal !== 0 ? Math.round((grossProfit / revenue.subtotal) * 1000) / 10 : null

    const sectionBlock = (titleKey: string, s: { rows: (AccountAgg & { amount: number })[]; subtotal: number }) => (
        <Fragment>
            <tr className="bg-gray-50">
                <td colSpan={3} className="border border-gray-300 px-4 py-2 font-semibold">
                    {t(titleKey)}
                </td>
            </tr>
            {s.rows.map((r) => (
                <tr key={r.code}>
                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{r.code}</td>
                    <td className="border border-gray-300 px-4 py-2">{accountName(r)}</td>
                    <td
                        className={
                            'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                            (r.amount < 0 ? 'text-red-600' : '')
                        }
                    >
                        {formatMoney(r.amount)}
                    </td>
                </tr>
            ))}
            <tr className="bg-gray-100 font-semibold">
                <td colSpan={2} className="border border-gray-300 px-4 py-2">
                    {t(titleKey)} — {t('finance.totalsLabel')}
                </td>
                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                    {formatMoney(s.subtotal)}
                </td>
            </tr>
        </Fragment>
    )

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.pnlTitle')}</h1>

            <Subnav />

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <PnlToolbar
                    from={from}
                    to={to}
                    presets={[
                        { key: 'thisMonth', ...thisMonth },
                        { key: 'lastMonth', ...lastMonth },
                        { key: 'thisYear', ...thisYear },
                    ]}
                />
            </Suspense>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount')}</th>
                    </tr>
                </thead>
                <tbody>
                    {sectionBlock('finance.accountType.revenue', revenue)}
                    {sectionBlock('finance.accountType.cogs', cogs)}
                    {/* 毛利(附毛利率)*/}
                    <tr className="font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.grossProfit')}
                            {marginPct !== null && (
                                <span className="ml-2 text-gray-500 font-normal text-sm">({marginPct}%)</span>
                            )}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(grossProfit)}
                        </td>
                    </tr>
                    {sectionBlock('finance.accountType.expense', expense)}
                    {/* 净利(正绿负红)*/}
                    <tr className="font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.netProfit')}
                        </td>
                        <td
                            className={
                                'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                                (netProfit >= 0 ? 'text-green-700' : 'text-red-600')
                            }
                        >
                            {formatMoney(netProfit)}
                        </td>
                    </tr>
                </tbody>
            </table>

            <p className="text-sm text-gray-500 mt-4">{t('finance.pnlNote')}</p>
        </div>
    )
}
