// app/finance/payables/page.tsx
// AP 账龄:ap_open_items 全量读取(补充 2a 起是两类单据的 UNION:已计价未结清的
// 进料批次 + 挂账开支;端口自应收页)。汇总条 + 按供应商分组小计,供应商按未结额
// 倒序;进料单据链接到 AP 单据详情页(批次编辑页链接在详情页内),开支单据
// 链接到开支详情页 /finance/expenses/[id],旁附类别标签。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare } from '@/lib/format'
import Subnav from '../Subnav'
import { BUCKETS, bucketPillClass } from '../agingBuckets'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// 视图列生成类型全可空;行进视图即非空,本地类型锁死
type ApRow = {
    doc_kind: 'inbound' | 'expense' | 'freight'
    doc_id: string
    doc_code: string
    inbound_batch_id: string | null
    supplier_id: string | null
    supplier_name: string | null
    // PAYEE-1a:往来对象可以是供应商【或员工】。supplier_* 对员工行诚实地为 NULL
    // —— 所以分组与显示一律走 counterparty_*,它们永远非空。
    counterparty_kind: 'supplier' | 'employee'
    counterparty_id: string
    counterparty_name: string
    doc_date: string
    doc_value_base: number
    settled_base: number
    open_base: number
    days_outstanding: number
    bucket: string
}

// PAYEE-1b:分组的主体不再"是一个供应商",而是"一个往来对象" ——
// 它可能是供应商,也可能是员工(报销)。kind 一起带上,因为屏幕上必须
// 说得出是哪一种:一个只有名字的分组,读的人分不出"张三公司"与"张三"。
type CounterpartyGroup = {
    name: string
    kind: 'supplier' | 'employee'
    rows: ApRow[]
    amount: number
    settled: number
    open: number
}

export default async function PayablesPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
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
    const totalOpen = Math.round(rows.reduce((s, r) => s + r.open_base, 0) * 100) / 100
    const bucketTotals = new Map<string, number>()
    for (const r of rows) {
        bucketTotals.set(r.bucket, (bucketTotals.get(r.bucket) ?? 0) + r.open_base)
    }

    // 按供应商分组,组内保持 doc_date 升序;供应商按未结额倒序
    // PAYEE-1b:按【往来对象】分组 —— 键与名字都取 counterparty_*。
    // 【为什么不能再用 supplier_id ?? '—'】员工行的 supplier_id 是 NULL,
    // 于是所有员工的欠款会被并进同一个叫「—」的分组里:既分不出是谁,
    // 也点不开。视图给的 counterparty_id / counterparty_name 永远非空,
    // 所以这里不需要任何兜底 —— 出现兜底就说明视图那侧出了问题。
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
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDate')}</th>
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
                                <td className="border border-gray-300 px-4 py-2 text-sm" colSpan={3}>
                                    {g.name}（{t('finance.counterpartyKind.' + g.kind)}） — {t('finance.totalsLabel')}
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
