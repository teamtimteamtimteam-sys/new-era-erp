// app/finance/cashflow/page.tsx
// 现金流量表(FIN-30)。与损益表、资产负债表并列,同一套期间控件。
//
// 【本页不算账】数字全部来自 db 的 cash_flow_statement(from, to) —— 一份实现,
// 页面只负责画。理由见 AGENTS.md「预览页面必须问数据库」那一节:同一个数在
// TypeScript 里再算一遍,两份实现写下的当天一致、之后无声漂移,而人们信的
// 偏偏是看得见的那一个。
//
// 【三件事页面必须如实说出来,不许美化】
//   * 汇率变动对现金的影响:它【不是现金流】,列在三段之下,与三段视觉分开;
//   * 未归类(手工分录):按构造无法归类,单列一行并给出提示,不塞进经营;
//   * 对不上(ties=false):直接说对不上,并把两个数并排列出来 ——
//     印一个不平的数比不印更坏。
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import CashflowToolbar from './CashflowToolbar'

type Cf = {
    period_from: string
    period_to: string
    opening_cash: number
    operating: number
    investing: number
    financing: number
    unclassified: number
    fx_effect: number
    closing_cash: number
    closing_cash_balance_sheet: number
    ties: boolean
    entries: { code: string; entry_date: string; source_type: string; memo: string | null; section: string; net: number }[]
}

const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)

export default async function CashflowPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    // 预设与损益表【逐字一致】—— 三张报表的"本月/上月/今年"必须指同样的区间
    const now = new Date()
    const y = now.getUTCFullYear()
    const m = now.getUTCMonth()
    const thisMonth = { from: ymdUtc(new Date(Date.UTC(y, m, 1))), to: ymdUtc(new Date(Date.UTC(y, m + 1, 0))) }
    const lastMonth = { from: ymdUtc(new Date(Date.UTC(y, m - 1, 1))), to: ymdUtc(new Date(Date.UTC(y, m, 0))) }
    const thisYear = { from: `${y}-01-01`, to: `${y}-12-31` }

    const { dateFrom, dateTo } = parseDateRange(sp)
    const from = dateFrom || thisMonth.from
    const to = dateTo || thisMonth.to

    const { data, error } = await supabase.rpc('cash_flow_statement', { p_from: from, p_to: to })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.cashflowTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }
    const cf = data as unknown as Cf

    // 预设键与损益表【逐字一致】(finance.presets.* 由工具栏自己翻译)
    const presets = [
        { key: 'thisMonth', ...thisMonth },
        { key: 'lastMonth', ...lastMonth },
        { key: 'thisYear', ...thisYear },
    ]

    const money = (n: number) => formatMoney(n)
    const sign = (n: number) => (n < 0 ? 'text-red-700' : n > 0 ? 'text-green-700' : 'text-gray-500')

    const Row = ({ label, value, bold = false, hint }: { label: string; value: number; bold?: boolean; hint?: string }) => (
        <tr className={bold ? 'font-bold bg-gray-50' : ''}>
            <td className="border border-gray-300 px-3 py-2 text-sm">
                {label}
                {hint && <span className="block text-xs font-normal text-gray-500 mt-0.5">{hint}</span>}
            </td>
            <td className={'border border-gray-300 px-3 py-2 text-right font-mono text-sm ' + sign(value)}>
                {money(value)}
            </td>
        </tr>
    )

    return (
        <div className="p-4 sm:p-8 max-w-4xl">
            <h1 className="text-2xl font-bold mb-2">{t('finance.cashflowTitle')}</h1>
            <p className="text-sm text-gray-600 mb-4">{t('finance.cashflowDesc', { ccy: baseCurrency })}</p>
            <Subnav />
            <Suspense fallback={null}>
                <CashflowToolbar from={from} to={to} presets={presets} />
            </Suspense>

            {/* 【对不上就说对不上】Part D 的自检:两个独立算出来的期末现金不等,
                说明这张表是错的 —— 把两个数并排摆出来,不印一个不平的数了事。 */}
            {!cf.ties && (
                <div className="bg-red-100 border border-red-400 text-red-800 px-4 py-3 rounded mb-4">
                    <p className="font-bold">{t('finance.cashflowDoesNotTie')}</p>
                    <p className="text-sm mt-1">
                        {t('finance.cashflowTieDetail', {
                            computed: money(cf.closing_cash),
                            balance: money(cf.closing_cash_balance_sheet),
                            diff: money(Math.round((cf.closing_cash_balance_sheet - cf.closing_cash) * 100) / 100),
                        })}
                    </p>
                </div>
            )}

            <table className="w-full border-collapse border border-gray-300 mb-4">
                <tbody>
                    <Row label={t('finance.cashflowOpening')} value={cf.opening_cash} bold />
                    <Row label={t('finance.cashflowOperating')} value={cf.operating} />
                    <Row label={t('finance.cashflowInvesting')} value={cf.investing} />
                    <Row label={t('finance.cashflowFinancing')} value={cf.financing} />
                    {cf.unclassified !== 0 && (
                        <Row
                            label={t('finance.cashflowUnclassified')}
                            value={cf.unclassified}
                            hint={t('finance.cashflowUnclassifiedHint')}
                        />
                    )}
                    {/* 汇率影响【不是现金流】—— 视觉上与三段分开,不参与"活动"的小计 */}
                    <Row
                        label={t('finance.cashflowFxEffect')}
                        value={cf.fx_effect}
                        hint={t('finance.cashflowFxEffectHint')}
                    />
                    <Row label={t('finance.cashflowClosing')} value={cf.closing_cash} bold />
                </tbody>
            </table>

            <h2 className="font-bold mb-2">{t('finance.cashflowDetail')}</h2>
            <table className="w-full border-collapse border border-gray-300">
                <thead>
                    <tr className="bg-gray-100">
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('finance.colDate')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('finance.cashflowSection')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('finance.colAmount')}</th>
                    </tr>
                </thead>
                <tbody>
                    {cf.entries.length === 0 && (
                        <tr>
                            <td colSpan={4} className="border border-gray-300 px-3 py-6 text-center text-sm text-gray-500">
                                {t('finance.cashflowNoMovement')}
                            </td>
                        </tr>
                    )}
                    {cf.entries.map((e) => (
                        <tr key={e.code}>
                            <td className="border border-gray-300 px-3 py-2 text-sm">{e.entry_date}</td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                <span className="font-mono">{e.code}</span>
                                {e.memo && <span className="block text-xs text-gray-500">{e.memo}</span>}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {t('finance.cashflowSectionName.' + e.section)}
                            </td>
                            <td className={'border border-gray-300 px-3 py-2 text-right font-mono text-sm ' + sign(e.net)}>
                                {money(e.net)}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
        </div>
    )
}
