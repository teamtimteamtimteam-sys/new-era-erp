// app/finance/freight/page.tsx
// 运费单据列表(FRT-1)。运费【资本化进批次成本】—— 借方进 1200/5000,
// 贷方记在【货代】名下,与材料供应商的应付是两笔账。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type FreightRow = {
    id: string
    code: string
    doc_date: string
    amount_base: number
    allocation_basis: string
    payment_status: string
    status: string
    suppliers: { legal_name: string } | null
}

export default async function FreightListPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()

    const rows = mustRows(
        await supabase
            .from('freight_documents')
            .select('id, code, doc_date, amount_base, allocation_basis, payment_status, status, suppliers ( legal_name )')
            .is('deleted_at', null)
            .order('doc_date', { ascending: false })
            .limit(200),
        'freight_documents'
    ) as unknown as FreightRow[]

    return (
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('finance.freight.listTitle')}</h1>
                <Link href="/finance/freight/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                    {t('finance.freight.addButton')}
                </Link>
            </div>

            {/* 资本化的代价,写在人看得见的地方:错的分摊藏在存货里,不显示在损益表上 */}
            <p className="text-sm text-gray-600 mb-4 max-w-3xl">{t('finance.freight.intro')}</p>

            {rows.length === 0 ? (
                <p className="text-gray-500">{t('finance.freight.empty')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colCode')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colDate')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colForwarder')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.freight.colAmount')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colBasis')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colPayment')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id} className={r.status === 'reversed' ? 'text-gray-400 line-through' : ''}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link href={`/finance/freight/${r.id}`} className="text-blue-600 hover:underline">
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.doc_date}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.suppliers?.legal_name ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatAmount(r.amount_base, baseCurrency)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {t('finance.freight.basis.' + r.allocation_basis)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {t('finance.freight.payment.' + r.payment_status)}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
