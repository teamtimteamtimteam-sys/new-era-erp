// app/finance/payables/page.tsx
// AP 账龄:三类单据的 UNION(已计价未结清的进料批次 + 挂账开支 + 未付运费单)。
// 汇总条 + 按往来对象分组小计,往来对象按未结额倒序;进料单据链接到 AP 单据详情页
// (批次编辑页链接在详情页内),开支单据链接到开支详情页 /finance/expenses/[id],
// 运费单链接到 /finance/freight/[id],旁附类别标签。
//
// ★【AGING-1:本页改读 ap_aging_asof(as_of),不再直接读 ap_open_items】★
//   【为什么把当前这一页也切过去,而不是"今天走视图、过去走函数"】
//   那会是【同一条档位边界的两份实现】,而这个仓库为这个形状反复付过账。
//   代价是当前这个数字从此由新代码给出 —— 所以它由 db/fixtures/135 的 A 臂
//   【逐行逐列】钉住:函数截至今天与那张视图两个方向的差集都必须为空。
//   视图本身留着(别的消费方在读),只是这两页不再读它。
//
// 【本页不算账】(OPS-16)未结合计与四档合计都由函数给出,页面不再自己 reduce ——
//   屏幕上那个数与 CSV 里那个数因此是同一个数,而不是两次相同的加法。
//   分组小计仍在本页算:它是【展示上的分组】,不是账龄口径的一部分,
//   而导出【刻意不含】它(小计行会把电子表格里的透视表全部弄坏)。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import { BUCKETS, bucketPillClass } from '../agingBuckets'
import { readAging, parseAsOf, type AgingRowAp, type AgingReport } from '../agingAsOf'
import AgingAsOfControl from '../AgingAsOfControl'
import AgingAsOfNotice from '../AgingAsOfNotice'
import { localizeFinanceError } from '../financeErrorCodes'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

// ★ CONV-4:不套 DataTable —— 按往来对象【动态分组】+ 组内小计,与
//   balance-sheet/pnl/trial-balance 撞见的同一个分组缺口(见那三页顶注)。
//   只套 ListPage 外壳,表本身按兵不动。

// PAYEE-1b:分组的主体不再"是一个供应商",而是"一个往来对象" ——
// 它可能是供应商,也可能是员工(报销)。kind 一起带上,因为屏幕上必须
// 说得出是哪一种:一个只有名字的分组,读的人分不出"张三公司"与"张三"。
type CounterpartyGroup = {
    name: string
    kind: 'supplier' | 'employee'
    rows: AgingRowAp[]
    amount: number
    settled: number
    open: number
}

export default async function PayablesPage({
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

    let report: AgingReport<AgingRowAp>
    try {
        report = await readAging<AgingRowAp>('ap', asOf)
    } catch (e) {
        // 【具名拒绝按名说出来】AGING_AS_OF_FUTURE 与权限拒绝都会走到这里。
        // 一串机器文本落在屏幕上,读的人无从判断是自己填错了还是系统坏了 ——
        // docs/machine-text-reaching-humans.md 那一条。
        const msg = await localizeFinanceError(e instanceof Error ? e.message : String(e))
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.payablesTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <p className="mt-2 text-sm">{msg}</p>
                </div>
            </div>
        )
    }

    const rows = report.rows

    // 按往来对象分组,组内保持 doc_date 升序;往来对象按未结额倒序
    // 【为什么这里不需要任何兜底】视图/函数给的 counterparty_id 与
    // counterparty_name 永远非空;出现兜底就说明底下那一侧出了问题。
    const groupMap = new Map<string, CounterpartyGroup>()
    for (const r of rows) {
        const key = r.counterparty_id
        let g = groupMap.get(key)
        if (!g) {
            g = { name: r.counterparty_name, kind: r.counterparty_kind,
                  rows: [], amount: 0, settled: 0, open: 0 }
            groupMap.set(key, g)
        }
        g.rows.push(r)
        g.amount += r.doc_value_base
        g.settled += r.settled_base
        g.open += r.open_base
    }
    const groups = Array.from(groupMap.values()).sort((a, b) => b.open - a.open)

    const exportHref = report.is_past
        ? `/finance/payables/export?as_of=${report.as_of}`
        : '/finance/payables/export'

    return (
        <ListPage
            title={
                <>
                    {t('finance.payablesTitle')}
                    {report.is_past && (
                        <span className="ml-3 align-middle text-base font-normal text-amber-700">
                            {t('finance.agingAsOf.headingSuffix', { date: report.as_of })}
                        </span>
                    )}
                </>
            }
            actions={
                <Link
                    href="/finance/payments/new?direction=out"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.recordPayment')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
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

            {/* 汇总条:未结合计 + 四档账龄(90+ 标红)。数字来自函数,本页不加总。*/}
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
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
                        {/* AGING-1:到期日露出来,而【档位不按它分】—— 见 finance.agingAsOf.dueDateNote */}
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.agingAsOf.colDueDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount', { ccy: baseCurrency })}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colSettled')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDays')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g, gi) => (
                        [
                            ...g.rows.map((r, ri) => (
                                <tr key={r.doc_id}>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {ri === 0 ? (
                                            <>
                                                {g.name}
                                                <span className="ml-2 px-1.5 py-0.5 rounded text-[11px] bg-gray-200 text-gray-700">
                                                    {t('finance.counterpartyKind.' + g.kind)}
                                                </span>
                                            </>
                                        ) : ''}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        {/* FRT-1:三种单据,三个去处。【认不出的种类不给链接】——
                                            原来是二分的 else,新来的 freight 会被送进
                                            /finance/expenses/<freight-id> 然后 404;而"点开是空的"
                                            读起来像数据出了问题,不像少了一张页面,下一个人会去
                                            查错的地方(LINKS-1 的教训)。 */}
                                        {r.doc_kind === 'inbound' ? (
                                            <Link
                                                href={`/finance/payables/${r.doc_id}`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {r.doc_code}
                                            </Link>
                                        ) : r.doc_kind === 'expense' ? (
                                            <>
                                                <Link
                                                    href={`/finance/expenses/${r.doc_id}`}
                                                    className="text-blue-600 hover:underline"
                                                >
                                                    {r.doc_code}
                                                </Link>
                                                <span className="ml-2 px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-500">
                                                    {t('finance.docKind.expense')}
                                                </span>
                                            </>
                                        ) : r.doc_kind === 'freight' ? (
                                            <>
                                                <Link
                                                    href={`/finance/freight/${r.doc_id}`}
                                                    className="text-blue-600 hover:underline"
                                                >
                                                    {r.doc_code}
                                                </Link>
                                                <span className="ml-2 px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-500">
                                                    {t('finance.docKind.freight')}
                                                </span>
                                            </>
                                        ) : (
                                            <span className="font-mono">{r.doc_code}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">{r.doc_date}</td>
                                    {/* 【空的时候说出【为什么】空,不留一个破折号】AP 三支今天一张
                                        到期日都没有 —— 而一个光秃秃的「—」读起来像"数据没填",
                                        实情是这套系统里【还没有】这个事实(供应商账期 0/8 填了)。
                                        命名的缺席,不是空白。 */}
                                    <td className="border border-gray-300 px-4 py-2 text-sm">
                                        {r.due_date ?? (
                                            <span className="text-gray-400" title={t('finance.agingAsOf.noDueDateWhy')}>
                                                {t('finance.agingAsOf.noDueDate')}
                                            </span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatMoneyBare(r.doc_value_base, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatMoneyBare(r.settled_base, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
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
                            )),
                            <tr key={`subtotal-${gi}`} className="bg-gray-50 font-medium">
                                <td className="border border-gray-300 px-4 py-2 text-sm" colSpan={4}>
                                    {g.name} ({t('finance.counterpartyKind.' + g.kind)}) — {t('finance.totalsLabel')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.amount * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.settled * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoneyBare(Math.round(g.open * 100) / 100, '同表列头 金额 ({ccy}) —— 金额/已结/未结三列同为本位币')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2" />
                            </tr>,
                        ]
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {/* 【一个过去的时点上"没有"与今天"没有"不是同一句话】*/}
                                {report.is_past
                                    ? t('finance.agingAsOf.noOpenItemsAsOf', { date: report.as_of })
                                    : t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </ListPage>
    )
}
