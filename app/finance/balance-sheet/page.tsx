// app/finance/balance-sheet/page.tsx
// 资产负债表:截至日(as_of,默认今天)全部分录聚合。资产净额 = Σ借−Σ贷,
// 负债/权益净额 = Σ贷−Σ借;权益额外加"本期损益"合成行(收入−成本−费用,
// 同一截至日口径)。
//
// 【本页不算账】(OPS-16)数字全部来自 db 的 balance_sheet(as_of) —— 一份实现,
// 页面只负责画,与损益表、现金流量表同一个形状。
//
// 【FIN-23:本表【包含】year_close 分录 —— 与损益表刻意不对称】理由现在写在
// db/functions/balance_sheet.sql 与 db/functions/pnl_statement.sql 里,两边注释互指:
// 已结年度的损益行合计归零,3100 接住净结果,合成的"本期损益"行只剩结转后的活动。
// 损益表相反,【剔除】year_close,否则结转会把已结年度的损益表清成零。
// 改任何一边前先读两边;db/fixtures/28 用同一个期间同时问两个函数,把这条钉住。
//
// 底部 资产合计 vs 负债+权益合计,必须相等(不等出红警,理论不可能)。
import { Fragment, Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import BsToolbar from './BsToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type BsRow = { code: string; name_en: string; name_zh: string; net: number }
type BsSection = { rows: BsRow[]; subtotal: number }
type Bs = {
    as_of: string
    asset: BsSection
    liability: BsSection
    /** total = 科目行合计 + 本期损益合成行,屏幕上权益那一段显示的是它 */
    equity: BsSection & { total: number }
    current_earnings: number
    total_assets: number
    total_liab_equity: number
    balanced: boolean
}

export default async function BalanceSheetPage({
    searchParams,
}: {
    searchParams: Promise<{ as_of?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const requested = (sp.as_of ?? '').trim()
    const asOf = isYmd(requested) ? requested : new Date().toISOString().slice(0, 10)

    const { data, error } = await supabase.rpc('balance_sheet', { p_as_of: asOf })

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
    const bs = data as unknown as Bs

    const accountName = (r: BsRow) => (locale === 'zh' ? r.name_zh : r.name_en)

    const sectionBlock = (
        titleKey: string,
        s: BsSection,
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

            {!bs.balanced && (
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
                    {sectionBlock('finance.accountType.asset', bs.asset)}
                    {sectionBlock('finance.accountType.liability', bs.liability)}
                    {/* 权益:科目行 + 本期损益合成行,小计含两者 */}
                    {sectionBlock(
                        'finance.accountType.equity',
                        bs.equity,
                        { label: t('finance.currentEarnings'), value: bs.current_earnings },
                        bs.equity.total
                    )}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.totalAssets')}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(bs.total_assets)}
                        </td>
                    </tr>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.totalLiabEquity')}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatMoney(bs.total_liab_equity)}
                        </td>
                    </tr>
                </tfoot>
            </table>

            <p className="text-sm text-gray-500 mt-4">{t('finance.bsNote')}</p>
        </div>
    )
}
