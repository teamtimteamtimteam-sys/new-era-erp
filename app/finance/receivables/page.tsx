// app/finance/receivables/page.tsx
// AR 账龄:ar_open_items 全量读取(只含未结清销售,页级规模小,不分页)。
// 汇总条(未结合计 + 四档账龄,90+ 标红),按客户分组 + 客户小计行,
// 客户按未结额倒序;单据链接到 AR 单据详情页(批次编辑页链接在详情页内)。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import Subnav from '../Subnav'
import { BUCKETS, bucketPillClass } from '../agingBuckets'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// 视图列生成类型全可空;行进视图即非空,本地类型锁死(同 journal 详情 LineRow 手法)
type ArRow = {
    sales_record_id: string | null
    // SO-3a:应收两种单据('sale' 销售记录 / 'invoice' 订单流发票)。
    // sale 行的 doc 链接去应收单据页,invoice 行去发票页 —— 猜错链接是拿一个
    // 合法 uuid 开错页(看板 ap 分支的同一条)。
    doc_kind: string
    doc_code: string
    invoice_id: string | null
    invoice_code: string | null
    customer_id: string | null
    customer_name: string | null
    sale_date: string
    amount_base: number
    // SO-3a-fu1:本视图【现在】才有 settled_base —— 此前这里读的是一个不存在的
    // 列,于是"已结"整列空白、客户小计 NaN。补列而不是改读 settled_ccy:
    // 那会把单据币种印进本位币那一列(INV-1 的老错)。
    settled_base: number
    // CN-1:【已贷记】—— 贷项凭证让 open 变小,而 settled 一个字不动。
    // 少了这一列,这张表上 金额 − 已结 ≠ 未结,读的人会以为页面算错了;
    // 而它说的又是一件与"收过钱"完全不同的事:这一截【不用付了】。
    // sale 支恒为 0(贷项凭证只绑 order 型发票),那里的 0 是"确实没有"。
    credited_base: number
    open_base: number
    days_outstanding: number
    bucket: string
}

type CustomerGroup = {
    name: string
    rows: ArRow[]
    amount: number
    settled: number
    credited: number
    open: number
}

export default async function ReceivablesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('ar_open_items')
        .select('*')
        .order('sale_date', { ascending: true })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.receivablesTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = (data as unknown as ArRow[] | null) ?? []

    // 汇总:未结合计 + 分档
    const totalOpen = Math.round(rows.reduce((s, r) => s + r.open_base, 0) * 100) / 100
    const bucketTotals = new Map<string, number>()
    for (const r of rows) {
        bucketTotals.set(r.bucket, (bucketTotals.get(r.bucket) ?? 0) + r.open_base)
    }

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
                <h1 className="text-2xl font-bold">{t('finance.receivablesTitle')}</h1>
                <Link
                    href="/finance/payments/new?direction=in"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.recordReceipt')}
                </Link>
            </div>

            <Subnav />

            {/* ── SO-3b:这张表【一共有两种应收单据,而发货不产生第三种】────────
                选项 C 之下订单流的债生在【开票】那一刻;发货只是把合同负债换成
                收入,不再产生任何应收。所以这里说出来 —— 一个看着账龄的人最容易
                以为"发了货怎么没多出一笔应收",而那正是对的。 */}
            <p className="text-xs text-gray-500 mb-4">{t('finance.arKindsNote')}</p>

            {/* 汇总条:未结合计 + 四档账龄(90+ 标红)*/}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalOpen')}:</span>
                    <span className="font-mono font-bold">{formatAmount(totalOpen, baseCurrency)}</span>
                </div>
                {BUCKETS.map((b) => (
                    <div key={b}>
                        <span className="text-gray-600 mr-1">{t('finance.aging.' + b)}:</span>
                        <span className={'font-mono ' + (b === 'b90_plus' ? 'text-red-600 font-medium' : '')}>
                            {formatAmount(Math.round((bucketTotals.get(b) ?? 0) * 100) / 100, baseCurrency)}
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
                                <td className="border border-gray-300 px-4 py-2 text-sm" colSpan={4}>
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
                            <td colSpan={9} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
