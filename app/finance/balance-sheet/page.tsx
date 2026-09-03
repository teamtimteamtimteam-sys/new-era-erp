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
// 【推导只有一份】(FIN-DRILL)三表连接、刻意不过滤 status、以及符号规则,住在
// db/functions/journal_activity_lines.sql;pnl_statement / balance_sheet /
// account_ledger 三个读者共读它,调用点上只剩那两个开关。上面那句「先读两边」
// 因此指的只是两个开关本身,不再包括推导。
//
// 【科目行是下钻入口】(FIN-DRILL)点科目号进 /finance/ledger/[account],
// 带上本表自己的截至日。见下面 sectionBlock 里的注释。
//
// 底部 资产合计 vs 负债+权益合计,必须相等(不等出红警,理论不可能)。
import { Fragment, Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import BsToolbar from './BsToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

// ★ CONV-4:这一页【不】套 DataTable —— 它的表不是"记录的列表",是一份
//   按科目类型分组、每组自己算小计、末尾还有资产合计/负债权益合计两行
//   grand total 的财务报表。DataTable 的契约是"一行 = 一条记录、渲染
//   一次",没有"动态分组表头 + 小计行 + 跨组合计"的口子 —— 与 payables /
//   receivables 撞见的分组缺口是同一个形状(§⑧-8 的"聚合/分组"缺口,
//   这一刀量到 5 处:payables · receivables · balance-sheet · pnl ·
//   trial-balance)。给这个形状建一套通用能力需要专门的设计时间(至少要
//   想清楚"动态分组 + 固定三段分组"两种形状能不能共用一套 API),不是
//   这一刀能顺手做的事 —— 只套 ListPage 外壳,表本身按兵不动。

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
    // 列头「净额」不写币种,所以每格自己带 —— 本位币是数据,不是常量
    const baseCurrency = await getBaseCurrency()

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
                    {/* ── FIN-DRILL:科目行是下钻入口 ─────────────────────────
                        链接把【科目号】与【本表自己的截至日】一起带走。
                        mode=bs 一并决定年结开关(包含)与日期形状(累计,不设
                        起点)—— 见 /finance/ledger/[account] 的抬头:那两件事
                        总是配套的(FIN-23 的不对称),拆开就等于允许对不上的组合。
                        下钻页把区间如实标成"截至 X,累计",不标成一个月份。 */}
                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                        <Link
                            href={`/finance/ledger/${encodeURIComponent(r.code)}?mode=bs&as_of=${asOf}`}
                            className="text-blue-600 hover:underline"
                        >
                            {r.code}
                        </Link>
                    </td>
                    <td className="border border-gray-300 px-4 py-2">{accountName(r)}</td>
                    <td
                        className={
                            'border border-gray-300 px-4 py-2 text-right font-mono text-sm ' +
                            (r.net < 0 ? 'text-red-600' : '')
                        }
                    >
                        {formatAmount(r.net, baseCurrency)}
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
                        {formatAmount(extraRow.value, baseCurrency)}
                    </td>
                </tr>
            )}
            <tr className="bg-gray-100 font-semibold">
                <td colSpan={2} className="border border-gray-300 px-4 py-2">
                    {t(titleKey)} — {t('finance.totalsLabel')}
                </td>
                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                    {formatAmount(subtotalOverride ?? s.subtotal, baseCurrency)}
                </td>
            </tr>
        </Fragment>
    )

    return (
        <ListPage title={t('finance.bsTitle')} maxWidth="max-w-4xl" state={{ kind: 'ok' }}>
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
                            {formatAmount(bs.total_assets, baseCurrency)}
                        </td>
                    </tr>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={2} className="border border-gray-300 px-4 py-2">
                            {t('finance.totalLiabEquity')}
                        </td>
                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                            {formatAmount(bs.total_liab_equity, baseCurrency)}
                        </td>
                    </tr>
                </tfoot>
            </table>

            <p className="text-sm text-gray-500 mt-4">{t('finance.bsNote')}</p>
        </ListPage>
    )
}
