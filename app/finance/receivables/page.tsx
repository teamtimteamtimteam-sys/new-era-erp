// app/finance/receivables/page.tsx
// AR 账龄:两种单据(直接销售记录 + 订单流发票),页级规模小,不分页。
// 汇总条(未结合计 + 四档账龄,90+ 标红),按客户分组 + 客户小计行,
// 客户按未结额倒序;单据链接到 AR 单据详情页(批次编辑页链接在详情页内)。
//
// ★【AGING-1:本页改读 ar_aging_asof(as_of),不再直接读 ar_open_items】★
//   理由与 /finance/payables 逐字相同:两份实现的档位边界是这个仓库反复付账的
//   那个形状。当前这个数字由 db/fixtures/135 的 A 臂【逐行逐列】钉住 ——
//   函数截至今天与那张视图,两个方向的差集都必须为空。
//
// 【本页不算账】(OPS-16)未结合计与四档合计由函数给出;分组小计仍在本页算,
//   它是【展示上的分组】而不是账龄口径,导出刻意不含它。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import Subnav from '../Subnav'
import { BUCKETS, bucketPillClass } from '../agingBuckets'
import { readAging, parseAsOf, type AgingRowAr, type AgingReport } from '../agingAsOf'
import AgingAsOfControl from '../AgingAsOfControl'
import AgingAsOfNotice from '../AgingAsOfNotice'
import { localizeFinanceError } from '../financeErrorCodes'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type CustomerGroup = {
    name: string
    rows: AgingRowAr[]
    amount: number
    settled: number
    credited: number
    open: number
}

export default async function ReceivablesPage({
    searchParams,
}: {
    searchParams: Promise<{ as_of?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const asOf = parseAsOf(sp)
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    let report: AgingReport<AgingRowAr>
    try {
        report = await readAging<AgingRowAr>('ar', asOf)
    } catch (e) {
        // 具名拒绝按名说出来(AGING_AS_OF_FUTURE / 权限)——
        // docs/machine-text-reaching-humans.md 那一条。
        const msg = await localizeFinanceError(e instanceof Error ? e.message : String(e))
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.receivablesTitle')}</h1>
                <Subnav />
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <p className="mt-2 text-sm">{msg}</p>
                </div>
            </div>
        )
    }

    const rows = report.rows

    const exportHref = report.is_past
        ? `/finance/receivables/export?as_of=${report.as_of}`
        : '/finance/receivables/export'

    // 按客户分组,组内保持 sale_date 升序;客户按未结额倒序
    const groupMap = new Map<string, CustomerGroup>()
    for (const r of rows) {
        const key = r.customer_id ?? '—'
        let g = groupMap.get(key)
        if (!g) {
            g = { name: r.customer_name ?? '—', rows: [], amount: 0, settled: 0, credited: 0, open: 0 }
            groupMap.set(key, g)
        }
        g.rows.push(r)
        g.amount += r.amount_base
        g.settled += r.settled_base
        g.credited += r.credited_base
        g.open += r.open_base
    }
    const groups = Array.from(groupMap.values()).sort((a, b) => b.open - a.open)

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">
                    {t('finance.receivablesTitle')}
                    {report.is_past && (
                        <span className="ml-3 align-middle text-base font-normal text-amber-700">
                            {t('finance.agingAsOf.headingSuffix', { date: report.as_of })}
                        </span>
                    )}
                </h1>
                <Link
                    href="/finance/payments/new?direction=in"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.recordReceipt')}
                </Link>
            </div>

            <Subnav />

            <AgingAsOfControl asOf={report.as_of} today={report.today} exportHref={exportHref} />

            <AgingAsOfNotice
                asOf={report.as_of}
                today={report.today}
                isPast={report.is_past}
                beforeSystemStart={report.before_system_start}
                systemStartDate={report.system_start_date}
                amountBasis={report.amount_basis}
                unpricedExcluded={report.unpriced_excluded}
            />

            {/* ── SO-3b:这张表【一共有两种应收单据,而发货不产生第三种】────────
                选项 C 之下订单流的债生在【开票】那一刻;发货只是把合同负债换成
                收入,不再产生任何应收。所以这里说出来 —— 一个看着账龄的人最容易
                以为"发了货怎么没多出一笔应收",而那正是对的。 */}
            <p className="text-xs text-gray-500 mb-4">{t('finance.arKindsNote')}</p>

            {/* 汇总条:未结合计 + 四档账龄(90+ 标红)*/}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalOpen')}:</span>
                    <span className="font-mono font-bold">{formatAmount(report.total_open_base, baseCurrency)}</span>
                </div>
                {BUCKETS.map((b) => (
                    <div key={b}>
                        <span className="text-gray-600 mr-1">{t('finance.aging.' + b)}:</span>
                        <span className={'font-mono ' + (b === 'b90_plus' ? 'text-red-600 font-medium' : '')}>
                            {formatAmount(report.buckets[b] ?? 0, baseCurrency)}
                        </span>
                    </div>
                ))}
            </div>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCounterparty')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDocument')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('invoice.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
                        {/* AGING-1:到期日露出来,而【档位不按它分】—— AR 的发票支有,销售支借它挂着的发票的 */}
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.agingAsOf.colDueDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount', { ccy: baseCurrency })}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colSettled')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colCredited')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDays')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g, gi) => (
                        [
                            ...g.rows.map((r, ri) => {
                                return (
                                    <tr key={r.sales_record_id ?? r.invoice_id ?? `${gi}-${ri}`}>
                                        <td className="border border-gray-300 px-4 py-2">
                                            {ri === 0 ? g.name : ''}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                            {r.doc_kind === 'invoice' ? (
                                                <Link
                                                    href={`/finance/invoices/${r.invoice_id}`}
                                                    className="text-blue-600 hover:underline"
                                                >
                                                    {r.doc_code}
                                                </Link>
                                            ) : (
                                                <Link
                                                    href={`/finance/receivables/${r.sales_record_id}`}
                                                    className="text-blue-600 hover:underline"
                                                >
                                                    {r.doc_code}
                                                </Link>
                                            )}
                                            {r.doc_kind === 'invoice' && (
                                                <span className="ml-2 px-1.5 py-0.5 rounded text-xs bg-blue-100 text-blue-800">
                                                    {t('finance.docKind.invoice')}
                                                </span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                            {r.invoice_id && r.invoice_code ? (
                                                <Link
                                                    href={`/finance/invoices/${r.invoice_id}`}
                                                    className="text-blue-600 hover:underline"
                                                >
                                                    {r.invoice_code}
                                                </Link>
                                            ) : (
                                                <span className="text-gray-400">—</span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2">{r.sale_date}</td>
                                        {/* 【命名的缺席,不是空白】没有到期日的那些行,说的是这套系统里
                                            【还没有】这个事实(客户账期 0/3 填了),不是"数据漏填"。 */}
                                        <td className="border border-gray-300 px-4 py-2 text-sm">
                                            {r.due_date ?? (
                                                <span className="text-gray-400" title={t('finance.agingAsOf.noDueDateWhy')}>
                                                    {t('finance.agingAsOf.noDueDate')}
                                                </span>
                                            )}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                            {formatMoneyBare(r.amount_base, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                            {formatMoneyBare(r.settled_base, '同表列头 金额 ({ccy}) —— 金额/已结/已贷记/未结四列同为本位币')}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                            {formatMoneyBare(r.credited_base, '同表列头 金额 ({ccy}) —— 金额/已结/已贷记/未结四列同为本位币')}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm font-medium">
                                            {formatMoneyBare(r.open_base, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2">
                                            <span className={'px-2 py-1 rounded text-xs ' + bucketPillClass(r.bucket)}>
                                                {r.days_outstanding}
                                            </span>
                                        </td>
                                    </tr>
                                )
                            }),
                            <tr key={`subtotal-${gi}`} className="bg-gray-50 font-medium">
                                <td className="border border-gray-300 px-4 py-2 text-sm" colSpan={5}>
                                    {g.name} — {t('finance.totalsLabel')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.amount * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.settled * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/已贷记/未结四列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.credited * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/已贷记/未结四列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.open * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/已贷记/未结四列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2" />
                            </tr>,
                        ]
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={10} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {/* 一个过去的时点上"没有"与今天"没有"不是同一句话 */}
                                {report.is_past
                                    ? t('finance.agingAsOf.noOpenItemsAsOf', { date: report.as_of })
                                    : t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
