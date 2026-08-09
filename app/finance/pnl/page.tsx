// app/finance/pnl/page.tsx
// 损益表:期间内(from/to,默认本月)revenue/cogs/expense 三类科目的分录聚合。
// 收入 = Σ贷−Σ借,成本/费用 = Σ借−Σ贷;毛利 = 收入−成本(附毛利率),
// 净利 = 毛利−费用(正绿负红)。零发生额科目隐藏。
//
// 【本页不算账】(OPS-16)数字全部来自 db 的 pnl_statement(from, to) —— 一份实现,
// 页面只负责画,与现金流量表同一个形状。此前这里是一条 PostgREST select 加一段
// TypeScript 聚合;仪表盘要做期间对比,那会让同一套算术在两个地方各算一遍,而
// AGENTS.md「预览过账的屏幕要问数据库」已经点名过这个形状四次。
//
// 【year_close 的不对称在函数里】损益表剔除年结分录,资产负债表包含它;两个函数体
// 里的注释互指,理由写在那儿(FIN-23)。搬家【没有改动任何数字】—— 六个期间逐分
// 相同,证明在 OPS-16 的提交信息里。
import { Fragment, Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import PnlToolbar from './PnlToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type PnlRow = { code: string; name_en: string; name_zh: string; amount: number }
type PnlSection = { rows: PnlRow[]; subtotal: number }
type Pnl = {
    period_from: string
    period_to: string
    revenue: PnlSection
    cogs: PnlSection
    expense: PnlSection
    gross_profit: number
    net_profit: number
    /** 收入为零时为 null —— 0% 是个断言,"没有收入所以没有比率"不是 */
    margin_pct: number | null
}

const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)

export default async function PnlPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
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

    const { data, error } = await supabase.rpc('pnl_statement', { p_from: from, p_to: to })

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
    const pnl = data as unknown as Pnl

    const accountName = (r: PnlRow) => (locale === 'zh' ? r.name_zh : r.name_en)

    const sectionBlock = (titleKey: string, s: PnlSection) => (
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
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount', { ccy: baseCurrency })}</th>
                    </tr>
                </thead>
                <tbody>
                    {sectionBlock('finance.accountType.revenue', pnl.revenue)}
                    {sectionBlock('finance.accountType.cogs', pnl.cogs)}
                    {/* 毛利(附毛利率)*/}
                    <tr className="font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.grossProfit')}
                            {pnl.margin_pct !== null && (
                                <span className="ml-2 text-gray-500 font-normal text-sm">({pnl.margin_pct}%)</span>
                            )}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(pnl.gross_profit)}
                        </td>
                    </tr>
                    {sectionBlock('finance.accountType.expense', pnl.expense)}
                    {/* 净利(正绿负红)*/}
                    <tr className="font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.netProfit')}
                        </td>
                        <td
                            className={
                                'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                                (pnl.net_profit >= 0 ? 'text-green-700' : 'text-red-600')
                            }
                        >
                            {formatMoney(pnl.net_profit)}
                        </td>
                    </tr>
                </tbody>
            </table>

            <p className="text-sm text-gray-500 mt-4">{t('finance.pnlNote')}</p>
        </div>
    )
}
