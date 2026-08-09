// app/margin/page.tsx
// 批次毛利 —— Doc 2 说"生意最需要、而 Xero 结构上做不出来"的那个数,Phase 3 完成定义
// 里欠着的一条。
//
// 【为什么在 /margin 而不是 /finance/... 或 /processing/...】它【跨两个模块】:收入在
// 财务,分摊成本在加工,而没有任何 live 角色同时持有两个模块。挂进任一模块的路由树,
// 就会被那个模块的 requireModule 挡掉另一半读者 —— 于是它在两边各有一个入口(财务
// 子导航、加工列表页页头),页面自己用 requireAnyModule 把关,与
// db/views/batch_margin.sql 的 OR 谓词同形。moduleForPath 对本路由返回 null:
// 它【不受模块目录管辖】,与 /me、/my-reviews 同一类。
//
// 【本页不算账】数字全部来自 db 的 batch_margin。三个限定词【跟着每一行走】,
// 不是页脚的一句说明:
//   * margin_status —— 算不出来时说出【是哪一种】算不出来(没有加工单 / 有单无单位成本),
//     并且【绝不显示 0 或 0%】。COALESCE(unit_cost,0) 会把 live 上三个批次印成 100% 毛利,
//     那是"权利推导、消耗记录"那条规律的教科书式发作:收入被记录,成本靠推导,
//     推导的一半缺席,结果既合理又错误且不报错。
//   * cost_incomplete —— 有未计价输入按零计入,毛利【被高估】(经再加工传染)。
//   * is_stale —— 分摊之后成本又动了,单位成本过期。
//
// 【总账口径 vs 管理口径,两个都对】record_output_sale 过账 COGS 一次且永不重述;
// 重分摊把差额记在当期的单据层(FIN-24)。本页给的是【管理口径】(当前单位成本),
// 屏幕上写明这一点,并在两者不同时把总账那个数并列出来 —— 而不是二选一装作没有分歧。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoney } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { requireAnyModule, requireDataClass } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type MarginRow = {
    output_batch_id: string
    batch_code: string
    material_name: string
    qty_sold: number
    revenue_base: number
    run_code: string | null
    unit_cost_base: number | null
    cost_current_base: number | null
    margin_base: number | null
    margin_pct: number | null
    margin_status: string
    cost_incomplete: boolean
    is_stale: boolean
    cogs_posted_base: number | null
    cogs_differs: boolean
}

export default async function MarginPage() {
    // 【任一模块】—— 单模块把关会对它该服务的两拨人各挡掉一拨。见文件头。
    const denied = await requireAnyModule([MOD.finance, MOD.processing])
    if (denied) return denied

    // 【模块之后还有数据类】视图的谓词是 data.view_prices AND (finance OR processing);
    // 只查模块的话,持 processing 而无 view_prices 的读者会过关然后读到零行 ——
    // 屏幕上是一张空表,与"没有可算毛利的批次"分不开。live 的 operations 正是这个处境。
    const priceDenied = await requireDataClass('data.view_prices', 'margin.title')
    if (priceDenied) return priceDenied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const rows = mustRows(
        await supabase
            .from('batch_margin')
            .select(
                'output_batch_id, batch_code, material_name, qty_sold, revenue_base, run_code, unit_cost_base, cost_current_base, margin_base, margin_pct, margin_status, cost_incomplete, is_stale, cogs_posted_base, cogs_differs'
            )
            .order('batch_code'),
        'batch_margin'
    ) as MarginRow[]

    const computable = rows.filter((r) => r.margin_status === 'ok')
    const revenueTotal = rows.reduce((s, r) => s + Number(r.revenue_base), 0)
    const computableRevenue = computable.reduce((s, r) => s + Number(r.revenue_base), 0)

    const Flag = ({ label, hint, tone }: { label: string; hint: string; tone: 'amber' | 'red' }) => (
        <span
            title={hint}
            className={
                'inline-block rounded px-1.5 py-0.5 text-xs whitespace-nowrap ' +
                (tone === 'red'
                    ? 'bg-red-100 text-red-800 border border-red-300'
                    : 'bg-amber-100 text-amber-900 border border-amber-300')
            }
        >
            {label}
        </span>
    )

    return (
        <div className="p-8 max-w-6xl">
            <h1 className="text-2xl font-bold mb-2">{t('margin.title')}</h1>
            <p className="text-gray-600 mb-4">{t('margin.subtitle', { ccy: baseCurrency })}</p>

            {/* 【用的是哪一个口径,写在屏幕上,不是写在文档里】 */}
            <div className="bg-blue-50 border border-blue-200 text-blue-900 px-4 py-3 rounded mb-6 max-w-3xl text-sm">
                <p className="font-medium">{t('margin.basisTitle')}</p>
                <p className="mt-1">{t('margin.basisBody')}</p>
            </div>

            {/* 覆盖率:能算的收入占多少 —— 三行 NULL 里藏着的正是最大的一笔,
                所以这句话必须在表格【上面】,不是脚注 */}
            {computable.length < rows.length && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-6 max-w-3xl">
                    <p className="font-medium">
                        {t('margin.coverage', {
                            computable: String(computable.length),
                            total: String(rows.length),
                        })}
                    </p>
                    <p className="text-sm mt-1">
                        {t('margin.coverageAmount', {
                            covered: formatMoney(computableRevenue),
                            total: formatMoney(revenueTotal),
                            ccy: baseCurrency,
                        })}
                    </p>
                </div>
            )}

            <div className="overflow-x-auto">
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('margin.colBatch')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('margin.colRun')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('margin.colQty')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('margin.colRevenue')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('margin.colCost')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('margin.colMargin')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('margin.colMarginPct')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('margin.colFlags')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => {
                            const ok = r.margin_status === 'ok'
                            return (
                                <tr key={r.output_batch_id} className={ok ? '' : 'bg-gray-50'}>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <Link href={`/output`} className="font-mono text-sm text-blue-600 hover:underline">
                                            {r.batch_code}
                                        </Link>
                                        <span className="block text-xs text-gray-500">{r.material_name}</span>
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                        {r.run_code ?? '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {r.qty_sold}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {formatMoney(r.revenue_base)}
                                    </td>
                                    {/* 【算不出来就说算不出来】—— 不是 0,也不是空白 */}
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {ok ? formatMoney(r.cost_current_base as number) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {ok ? formatMoney(r.margin_base as number) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                        {ok && r.margin_pct !== null ? `${r.margin_pct}%` : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-3 py-2">
                                        <div className="flex flex-wrap gap-1">
                                            {!ok && (
                                                <Flag
                                                    tone="red"
                                                    label={t('margin.status.' + r.margin_status)}
                                                    hint={t('margin.statusHint.' + r.margin_status)}
                                                />
                                            )}
                                            {r.cost_incomplete && (
                                                <Flag tone="amber" label={t('margin.flag.costIncomplete')} hint={t('margin.flagHint.costIncomplete')} />
                                            )}
                                            {r.is_stale && (
                                                <Flag tone="amber" label={t('margin.flag.stale')} hint={t('margin.flagHint.stale')} />
                                            )}
                                            {r.cogs_differs && (
                                                <Flag
                                                    tone="amber"
                                                    label={t('margin.flag.cogsDiffers', {
                                                        posted: formatMoney(r.cogs_posted_base as number),
                                                    })}
                                                    hint={t('margin.flagHint.cogsDiffers')}
                                                />
                                            )}
                                        </div>
                                    </td>
                                </tr>
                            )
                        })}
                        {rows.length === 0 && (
                            <tr>
                                <td colSpan={8} className="border border-gray-300 px-3 py-6 text-center text-gray-500">
                                    {t('margin.empty')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
            </div>

            <p className="text-sm text-gray-500 mt-4">{t('margin.note')}</p>
        </div>
    )
}
