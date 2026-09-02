// app/finance/freight/[id]/page.tsx
// 运费单详情:头部卡 + 【分摊明细】(每批分到多少、从什么数算出来的、
// 过账那一刻的在库比例)+ 关联分录。
//
// 【分摊明细就是这一页存在的理由】资本化之后,一次错的分摊藏在存货里而不是
// 显示在损益表上 —— 所以这一页把 basis_qty 与 in_stock_ratio 都摆出来,
// 让那个数可以被【重新导出】,而不是只能被相信。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatAmount } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import ReverseFreightControl from './ReverseFreightControl'

type AllocRow = {
    id: string
    amount_base: number
    basis_qty: number | null
    in_stock_ratio: number
    inbound_batches: { id: string; code: string; quantity: number; unit: string } | null
}

export default async function FreightDetailPage({ params }: { params: Promise<{ id: string }> }) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()

    // 【两条外键都指向 journal_entries，所以两个嵌套都要按约束名消歧】
    // （原分录 journal_entry_id / 冲销分录 reversal_entry_id）。不写约束名，
    // PostgREST 无从知道要哪一条，而它报的错读起来像是“这一列不存在”。
    const { data: doc } = await supabase
        .from('freight_documents')
        .select('id, code, doc_date, amount_ccy, currency, fx_rate, amount_base, allocation_basis, payment_status, bank_account_code, notes, status, journal_entry_id, direction, container_id, reversed_at, reversal_reason, reversal_entry_id, suppliers ( legal_name ), containers ( id, code ), journal_entries!freight_documents_journal_entry_id_fkey ( id, code ), reversal_entry:journal_entries!freight_documents_reversal_entry_id_fkey ( id, code )')
        .eq('id', id)
        .is('deleted_at', null)
        .maybeSingle()
    if (!doc) notFound()
    const d = doc as unknown as {
        code: string; doc_date: string; amount_ccy: number; currency: string; fx_rate: number
        amount_base: number; allocation_basis: string; payment_status: string
        bank_account_code: string | null; notes: string | null; status: string
        direction: string
        reversed_at: string | null; reversal_reason: string | null
        suppliers: { legal_name: string } | null
        journal_entries: { id: string; code: string } | null
        containers: { id: string; code: string } | null
        reversal_entry: { id: string; code: string } | null
    }
    const outbound = d.direction === 'outbound'
    const reversed = d.status === 'reversed'

    // 【出境单据不查分摊行】不是"查了是空的" —— 库里的守卫保证它一行都不可能有
    // (EXPORT_FREIGHT_HAS_NO_ALLOCATIONS)。查一次再显示成空表,
    // 是把一个【结构上不存在】的东西显示成【暂时没有】。
    const allocs = outbound ? [] : mustRows(
        await supabase
            .from('freight_allocations')
            .select('id, amount_base, basis_qty, in_stock_ratio, inbound_batches ( id, code, quantity, unit )')
            .eq('freight_document_id', id),
        'freight_allocations'
    ) as unknown as AllocRow[]

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/freight" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex items-start justify-between gap-4 mb-4">
                <h1 className="text-2xl font-bold">
                    {d.code}
                    {/* 【方向就在单号旁边】它决定这笔钱去了 6300 还是 1200/5000 */}
                    <span className={'ml-3 align-middle text-xs font-sans px-2 py-0.5 rounded '
                        + (outbound ? 'bg-purple-100 text-purple-800' : 'bg-sky-100 text-sky-800')}>
                        {t('finance.freight.direction.' + d.direction)}
                    </span>
                </h1>
                {/* 已冲销的单据没有冲销钮 —— 服务端会按名拒(FREIGHT_ALREADY_REVERSED),
                    所以这里干脆不渲染一个注定被拒的控件 */}
                {!reversed && <ReverseFreightControl id={id} />}
            </div>

            {reversed && (
                <div className="border border-amber-300 bg-amber-50 text-amber-900 rounded px-4 py-3 mb-4 text-sm max-w-3xl">
                    <p className="font-medium mb-1">{t('finance.freight.reversedBanner')}</p>
                    <div className="grid grid-cols-2 gap-2">
                        <div><span className="text-amber-700">{t('finance.freight.colReversedAt')}: </span>{d.reversed_at ?? '—'}</div>
                        {d.reversal_entry && (
                            <div>
                                <span className="text-amber-700">{t('finance.freight.colReversalEntry')}: </span>
                                <Link href={`/finance/journal/${d.reversal_entry.id}`} className="text-blue-700 hover:underline font-mono">
                                    {d.reversal_entry.code}
                                </Link>
                            </div>
                        )}
                        <div className="col-span-2">
                            <span className="text-amber-700">{t('finance.freight.colReversalReason')}: </span>
                            {d.reversal_reason ?? '—'}
                        </div>
                    </div>
                </div>
            )}

            <div className="border border-gray-300 rounded-lg p-4 mb-6 grid grid-cols-2 gap-3 text-sm">
                <div><span className="text-gray-500">{t('finance.freight.colDate')}: </span>{d.doc_date}</div>
                {/* 【货代,不是材料供应商】—— 这一行就是本刀最要紧的那个区别 */}
                <div><span className="text-gray-500">{t('finance.freight.colForwarder')}: </span>{d.suppliers?.legal_name ?? '—'}</div>
                <div>
                    <span className="text-gray-500">{t('finance.freight.colAmount')}: </span>
                    <span className="font-mono">{formatAmount(d.amount_base, baseCurrency)}</span>
                </div>
                {/* 【出境单据不显示分摊口径】它在库里是 'stated' 只因为那一列 NOT NULL,
                    而出境根本不分摊 —— 把它当成一个"口径"显示出来就是在说一件没发生的事。 */}
                {!outbound && (
                    <div><span className="text-gray-500">{t('finance.freight.colBasis')}: </span>{t('finance.freight.basis.' + d.allocation_basis)}</div>
                )}
                {outbound && (
                    <div>
                        <span className="text-gray-500">{t('finance.freight.colContainer')}: </span>
                        {d.containers ? (
                            <Link href={`/logistics/containers/${d.containers.id}`} className="text-blue-600 hover:underline font-mono">
                                {d.containers.code}
                            </Link>
                        ) : (
                            <span className="text-gray-400">{t('finance.freight.selectContainer')}</span>
                        )}
                    </div>
                )}
                <div><span className="text-gray-500">{t('finance.freight.colPayment')}: </span>{t('finance.freight.payment.' + d.payment_status)}</div>
                {d.journal_entries && (
                    <div>
                        <span className="text-gray-500">{t('finance.freight.colEntry')}: </span>
                        <Link href={`/finance/journal/${d.journal_entries.id}`} className="text-blue-600 hover:underline font-mono">
                            {d.journal_entries.code}
                        </Link>
                    </div>
                )}
                {d.notes && <div className="col-span-2 text-gray-600">{d.notes}</div>}
            </div>

            {/* 【空状态要说出它是哪一种空】出境单据没有分摊行,不是"还没有记" ——
                所以这里是一句话,不是一张空表。 */}
            {outbound ? (
                <>
                    <h2 className="text-lg font-semibold mb-2">{t('finance.freight.outboundNoAllocTitle')}</h2>
                    <p className="text-sm text-gray-600 max-w-3xl">{t('finance.freight.outboundNoAlloc')}</p>
                </>
            ) : (
            <>
            <h2 className="text-lg font-semibold mb-2">{t('finance.freight.allocTitle')}</h2>
            <p className="text-sm text-gray-600 mb-3 max-w-3xl">{t('finance.freight.allocHint')}</p>
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.freight.colBatch')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.freight.colBasisQty')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.freight.colShare')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.freight.colInStock')}</th>
                    </tr>
                </thead>
                <tbody>
                    {allocs.map((a) => (
                        <tr key={a.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                {a.inbound_batches ? (
                                    <Link href={`/inbound/${a.inbound_batches.id}/edit`} className="text-blue-600 hover:underline">
                                        {a.inbound_batches.code}
                                    </Link>
                                ) : '—'}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {/* stated 口径没有中间量 —— 金额是人直接列明的,空着是【对的】 */}
                                {a.basis_qty === null
                                    ? <span className="text-gray-400">{t('finance.freight.basisQtyStated')}</span>
                                    : a.basis_qty}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatAmount(a.amount_base, baseCurrency)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {(Number(a.in_stock_ratio) * 100).toFixed(1)}%
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            </>
            )}
        </div>
    )
}
