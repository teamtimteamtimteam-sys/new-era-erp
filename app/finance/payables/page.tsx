// app/finance/payables/page.tsx
// AP 账龄:ap_open_items 全量读取(只含已计价、未结清的进料批次;端口自应收页)。
// 汇总条 + 按供应商分组小计,供应商按未结额倒序;单据直链进料批次编辑页。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatUsd } from '@/lib/format'
import Subnav from '../Subnav'
import { BUCKETS, bucketPillClass } from '../agingBuckets'

// 视图列生成类型全可空;行进视图即非空,本地类型锁死
type ApRow = {
    inbound_batch_id: string
    doc_code: string
    supplier_id: string | null
    supplier_name: string | null
    doc_date: string
    amount_usd: number
    settled_usd: number
    open_usd: number
    days_outstanding: number
    bucket: string
}

type SupplierGroup = {
    name: string
    rows: ApRow[]
    amount: number
    settled: number
    open: number
}

export default async function PayablesPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const { data, error } = await supabase
        .from('ap_open_items')
        .select('*')
        .order('doc_date', { ascending: true })

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.payablesTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = (data as unknown as ApRow[] | null) ?? []

    // 汇总:未结合计 + 分档
    const totalOpen = Math.round(rows.reduce((s, r) => s + r.open_usd, 0) * 100) / 100
    const bucketTotals = new Map<string, number>()
    for (const r of rows) {
        bucketTotals.set(r.bucket, (bucketTotals.get(r.bucket) ?? 0) + r.open_usd)
    }

    // 按供应商分组,组内保持 doc_date 升序;供应商按未结额倒序
    const groupMap = new Map<string, SupplierGroup>()
    for (const r of rows) {
        const key = r.supplier_id ?? '—'
        let g = groupMap.get(key)
        if (!g) {
            g = { name: r.supplier_name ?? '—', rows: [], amount: 0, settled: 0, open: 0 }
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
                <h1 className="text-2xl font-bold">{t('finance.payablesTitle')}</h1>
                <Link
                    href="/finance/payments/new?direction=out"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.recordPayment')}
                </Link>
            </div>

            <Subnav />

            {/* 汇总条:未结合计 + 四档账龄(90+ 标红)*/}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.totalOpen')}:</span>
                    <span className="font-mono font-bold">{formatUsd(totalOpen)}</span>
                </div>
                {BUCKETS.map((b) => (
                    <div key={b}>
                        <span className="text-gray-600 mr-1">{t('finance.aging.' + b)}:</span>
                        <span className={'font-mono ' + (b === 'b90_plus' ? 'text-red-600 font-medium' : '')}>
                            {formatUsd(Math.round((bucketTotals.get(b) ?? 0) * 100) / 100)}
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
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAmount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colSettled')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDays')}</th>
                    </tr>
                </thead>
                <tbody>
                    {groups.map((g, gi) => (
                        [
                            ...g.rows.map((r, ri) => (
                                <tr key={r.inbound_batch_id}>
                                    <td className="border border-gray-300 px-4 py-2">
                                        {ri === 0 ? g.name : ''}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        <Link
                                            href={`/inbound/${r.inbound_batch_id}/edit`}
                                            className="text-blue-600 hover:underline"
                                        >
                                            {r.doc_code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">{r.doc_date}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatUsd(r.amount_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {formatUsd(r.settled_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm font-medium">
                                        {formatUsd(r.open_usd)}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">
                                        <span className={'px-2 py-1 rounded text-xs ' + bucketPillClass(r.bucket)}>
                                            {r.days_outstanding}
                                        </span>
                                    </td>
                                </tr>
                            )),
                            <tr key={`subtotal-${gi}`} className="bg-gray-50 font-medium">
                                <td className="border border-gray-300 px-4 py-2 text-sm" colSpan={3}>
                                    {g.name} — {t('finance.totalsLabel')}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatUsd(Math.round(g.amount * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatUsd(Math.round(g.settled * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatUsd(Math.round(g.open * 100) / 100)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2" />
                            </tr>,
                        ]
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
