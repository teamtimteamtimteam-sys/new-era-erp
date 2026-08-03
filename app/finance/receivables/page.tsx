// app/finance/receivables/page.tsx
// AR 账龄:ar_open_items 全量读取(只含未结清销售,页级规模小,不分页)。
// 汇总条(未结合计 + 四档账龄,90+ 标红),按客户分组 + 客户小计行,
// 客户按未结额倒序;单据链接到 AR 单据详情页(批次编辑页链接在详情页内)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import { BUCKETS, bucketPillClass } from '../agingBuckets'

// 视图列生成类型全可空;行进视图即非空,本地类型锁死(同 journal 详情 LineRow 手法)
type ArRow = {
    sales_record_id: string
    doc_code: string
    invoice_id: string | null
    invoice_code: string | null
    customer_id: string | null
    customer_name: string | null
    sale_date: string
    amount_usd: number
    settled_usd: number
    open_usd: number
    days_outstanding: number
    bucket: string
}

type CustomerGroup = {
    name: string
    rows: ArRow[]
    amount: number
    settled: number
    open: number
}

export default async function ReceivablesPage() {
    const supabase = await createClient()
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
    const totalOpen = Math.round(rows.reduce((s, r) => s + r.open_usd, 0) * 100) / 100
    const bucketTotals = new Map<string, number>()
    for (const r of rows) {
        bucketTotals.set(r.bucket, (bucketTotals.get(r.bucket) ?? 0) + r.open_usd)
    }

    // 按客户分组,组内保持 sale_date 升序;客户按未结额倒序
    const groupMap = new Map<string, CustomerGroup>()
    for (const r of rows) {
        const key = r.customer_id ?? '—'
        let g = groupMap.get(key)
        if (!g) {
            g = { name: r.customer_name ?? '—', rows: [], amount: 0, settled: 0, open: 0 }
            groupMap.set(key, g)
        }
        g.rows.push(r)
        g.amount += r.amount_usd
        g.settled += r.settled_usd
        g.open += r.open_usd
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

            {/* 汇总条:未结合计 + 四档账龄(90+ 标红)*/}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalOpen')}:</span>
                    <span className="font-mono font-bold">{formatMoney(totalOpen)}</span>
                </div>
                {BUCKETS.map((b) => (
                    <div key={b}>
                        <span className="text-gray-600 mr-1">{t('finance.aging.' + b)}:</span>
                        <span className={'font-mono ' + (b === 'b90_plus' ? 'text-red-600 font-medium' : '')}>
                            {formatMoney(Math.round((bucketTotals.get(b) ?? 0) * 100) / 100)}
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
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colSettled')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDays')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g, gi) => (
                        [
                            ...g.rows.map((r, ri) => {
                                return (
                                    <tr key={r.sales_record_id}>
                                        <td className="border border-gray-300 px-4 py-2">
                                            {ri === 0 ? g.name : ''}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                            <Link
                                                href={`/finance/receivables/${r.sales_record_id}`}
                                                className="text-blue-600 hover:underline"
                                            >
                                                {r.doc_code}
                                            </Link>
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
                                            {formatMoney(r.amount_usd)}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                            {formatMoney(r.settled_usd)}
                                        </td>
                                        <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm font-medium">
                                            {formatMoney(r.open_usd)}
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
                                    {formatMoney(Math.round(g.amount * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoney(Math.round(g.settled * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoney(Math.round(g.open * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2" />
                            </tr>,
                        ]
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
