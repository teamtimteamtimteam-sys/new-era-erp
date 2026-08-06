// app/finance/balance-sheet/page.tsx
// 资产负债表:截至日(as_of,默认今天)全部分录聚合。资产净额 = Σ借−Σ贷,
// 负债/权益净额 = Σ贷−Σ借;权益额外加"本期损益"合成行(收入−成本−费用,
// 同一截至日口径)。
// 【FIN-23:本表【包含】year_close 分录 —— 与损益表刻意不对称】已结年度的损益行
// 合计归零,3100 接住净结果,合成的"本期损益"行只剩结转后的活动 —— 自洽,
// 权益合计不变。损益表相反,【剔除】year_close(app/finance/pnl/page.tsx,注释
// 互指):否则结转会把已结年度的损益表清成零。改任何一边前先读两边。
// 底部 资产合计 vs 负债+权益合计,必须相等(不等出红警,理论不可能)。
import { Fragment, Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import BsToolbar from './BsToolbar'

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

export default async function BalanceSheetPage({
    searchParams,
}: {
    searchParams: Promise<{ as_of?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const requested = (sp.as_of ?? '').trim()
    const asOf = isYmd(requested) ? requested : new Date().toISOString().slice(0, 10)

    const { data, error } = await supabase
        .from('journal_lines')
        .select('debit, credit, accounts!inner(code, name_en, name_zh, account_type), journal_entries!inner(entry_date)')
        .lte('journal_entries.entry_date', asOf)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.bsTitle')}</h1>
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

    const section = (type: string, debitPositive: boolean) => {
        const rows = Array.from(agg.values())
            .filter((a) => a.account_type === type && (a.debits !== 0 || a.credits !== 0))
            .map((a) => ({
                ...a,
                net: round2(debitPositive ? a.debits - a.credits : a.credits - a.debits),
            }))
            .sort((a, b) => a.code.localeCompare(b.code))
        const subtotal = round2(rows.reduce((s, r) => s + r.net, 0))
        return { rows, subtotal }
    }

    const assets = section('asset', true)
    const liabilities = section('liability', false)
    const equity = section('equity', false)

    // 本期损益(截至日口径):收入 − 成本 − 费用,尚无年结分录 → 合成进权益
    const plNet = (type: string, creditPositive: boolean) =>
        round2(
            Array.from(agg.values())
                .filter((a) => a.account_type === type)
                .reduce(
                    (s, a) => s + (creditPositive ? a.credits - a.debits : a.debits - a.credits),
                    0
                )
        )
    const currentEarnings = round2(plNet('revenue', true) - plNet('cogs', false) - plNet('expense', false))

    const totalAssets = assets.subtotal
    const totalLiabEquity = round2(liabilities.subtotal + equity.subtotal + currentEarnings)
    const balanced = totalAssets === totalLiabEquity

    const sectionBlock = (
        titleKey: string,
        s: { rows: (AccountAgg & { net: number })[]; subtotal: number },
        extraRow?: { label: string; value: number },
        subtotalOverride?: number
    ) => (
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
                            (r.net < 0 ? 'text-red-600' : '')
                        }
                    >
                        {formatMoney(r.net)}
                    </td>
                </tr>
            ))}
            {extraRow && (
                <tr>
                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">—</td>
                    <td className="border border-gray-300 px-4 py-2">{extraRow.label}</td>
                    <td
                        className={
                            'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                            (extraRow.value < 0 ? 'text-red-600' : '')
                        }
                    >
                        {formatMoney(extraRow.value)}
                    </td>
                </tr>
            )}
            <tr className="bg-gray-100 font-semibold">
                <td colSpan={2} className="border border-gray-300 px-4 py-2">
                    {t(titleKey)} — {t('finance.totalsLabel')}
                </td>
                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                    {formatMoney(subtotalOverride ?? s.subtotal)}
                </td>
            </tr>
        </Fragment>
    )

    return (
        <div className="p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.bsTitle')}</h1>

            <Subnav />

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <BsToolbar asOf={asOf} />
            </Suspense>

            {!balanced && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 font-bold">
                    {t('finance.bsImbalance')}
                </div>
            )}

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colAccount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colNet')}</th>
                    </tr>
                </thead>
                <tbody>
                    {sectionBlock('finance.accountType.asset', assets)}
                    {sectionBlock('finance.accountType.liability', liabilities)}
                    {/* 权益:科目行 + 本期损益合成行,小计含两者 */}
                    {sectionBlock(
                        'finance.accountType.equity',
                        equity,
                        { label: t('finance.currentEarnings'), value: currentEarnings },
                        round2(equity.subtotal + currentEarnings)
                    )}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.totalAssets')}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(totalAssets)}
                        </td>
                    </tr>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.totalLiabEquity')}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(totalLiabEquity)}
                        </td>
                    </tr>
                </tfoot>
            </table>

            <p className="text-sm text-gray-500 mt-4">{t('finance.bsNote')}</p>
        </div>
    )
}
