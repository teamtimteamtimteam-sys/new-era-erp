// app/finance/freight/[id]/page.tsx
// 运费单详情:头部卡 + 【分摊明细】(每批分到多少、从什么数算出来的、
// 过账那一刻的在库比例)+ 关联分录。
//
// 【分摊明细就是这一页存在的理由】资本化之后,一次错的分摊藏在存货里而不是
// 显示在损益表上 —— 所以这一页把 basis_qty 与 in_stock_ratio 都摆出来,
// 让那个数可以被【重新导出】,而不是只能被相信。
//
// ★ CONV-9(2026-09-04):转成 ListPage + RecordHeader + DataTable。
//   【出口检查】这一页唯一的出口是冲销钮(ReverseFreightControl),它住在
//   RecordHeader 的 actions 槽里 —— 而详情页 `state` 恒为 'ok',children 永远画,
//   所以它不可能被任何空分支吃掉。见 docs/detail-page-template.md §⑤。
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
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader, type RecordField } from '@/app/components/ui/record-header'
import FreightAllocationsTable, { type FreightAllocRow } from './FreightAllocationsTable'

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

    // ★【行数据在服务端压平】baseCurrency 的金额格式只有服务端知道;
    //   批次链接过界的是 href 字符串,不是函数(CONV-1 §① 的通则)。
    const tableRows: FreightAllocRow[] = allocs.map((a) => ({
        id: a.id,
        batchCode: a.inbound_batches?.code ?? '—',
        batchHref: a.inbound_batches ? `/inbound/${a.inbound_batches.id}/edit` : null,
        basisQtyStated: a.basis_qty === null,
        basisQtyText: a.basis_qty === null ? t('finance.freight.basisQtyStated') : String(a.basis_qty),
        amountText: formatAmount(a.amount_base, baseCurrency),
        inStockText: `${(Number(a.in_stock_ratio) * 100).toFixed(1)}%`,
    }))

    // 抬头字段逐页不同 —— RecordHeader 只管盒子,不认识它们(见组件抬头)。
    const fields: RecordField[] = [
        { label: t('finance.freight.colDate'), value: d.doc_date },
        // 【货代,不是材料供应商】—— 这一行就是那个最要紧的区别
        { label: t('finance.freight.colForwarder'), value: d.suppliers?.legal_name ?? '—' },
        { label: t('finance.freight.colAmount'), value: formatAmount(d.amount_base, baseCurrency), mono: true },
    ]
    // 【出境单据不显示分摊口径】它在库里是 'stated' 只因为那一列 NOT NULL,
    // 而出境根本不分摊 —— 把它当成一个"口径"显示出来就是在说一件没发生的事。
    if (!outbound) {
        fields.push({
            label: t('finance.freight.colBasis'),
            value: t('finance.freight.basis.' + d.allocation_basis),
        })
    } else {
        fields.push({
            label: t('finance.freight.colContainer'),
            value: d.containers ? (
                <Link href={`/logistics/containers/${d.containers.id}`} className="text-blue-600 hover:underline font-mono">
                    {d.containers.code}
                </Link>
            ) : (
                <span className="text-gray-400">{t('finance.freight.selectContainer')}</span>
            ),
        })
    }
    fields.push({
        label: t('finance.freight.colPayment'),
        value: t('finance.freight.payment.' + d.payment_status),
    })
    if (d.journal_entries) {
        fields.push({
            label: t('finance.freight.colEntry'),
            value: (
                <Link href={`/finance/journal/${d.journal_entries.id}`} className="text-blue-600 hover:underline font-mono">
                    {d.journal_entries.code}
                </Link>
            ),
        })
    }
    if (d.notes) fields.push({ label: t('finance.freight.notes'), value: d.notes })

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={
                <Link href="/finance/freight" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={
                <>
                    {d.code}
                    {/* 【方向就在单号旁边】它决定这笔钱去了 6300 还是 1200/5000 */}
                    <span className={'ml-3 align-middle text-xs font-sans px-2 py-0.5 rounded '
                        + (outbound ? 'bg-purple-100 text-purple-800' : 'bg-sky-100 text-sky-800')}>
                        {t('finance.freight.direction.' + d.direction)}
                    </span>
                </>
            }
            // ★★ 详情页恒为 ok —— 记录在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                reversed ? (
                    <div className="border border-amber-300 bg-amber-50 text-amber-900 rounded px-4 py-3 mb-4 text-sm max-w-3xl">
                        <p className="font-medium mb-1">{t('finance.freight.reversedBanner')}</p>
                        {/* flex-wrap,不是 grid-cols-2:390px 上两列会把这一块顶宽,
                            而那正是 CONV-8 §⑥ 量到的「元凶多数不是表」那一族。 */}
                        <div className="flex flex-wrap gap-x-8 gap-y-1">
                            <div><span className="text-amber-700">{t('finance.freight.colReversedAt')}: </span>{d.reversed_at ?? '—'}</div>
                            {d.reversal_entry && (
                                <div>
                                    <span className="text-amber-700">{t('finance.freight.colReversalEntry')}: </span>
                                    <Link href={`/finance/journal/${d.reversal_entry.id}`} className="text-blue-700 hover:underline font-mono">
                                        {d.reversal_entry.code}
                                    </Link>
                                </div>
                            )}
                            <div className="w-full">
                                <span className="text-amber-700">{t('finance.freight.colReversalReason')}: </span>
                                {d.reversal_reason ?? '—'}
                            </div>
                        </div>
                    </div>
                ) : undefined
            }
        >
            <RecordHeader
                fields={fields}
                // 已冲销的单据没有冲销钮 —— 服务端会按名拒(FREIGHT_ALREADY_REVERSED),
                // 所以这里干脆不渲染一个注定被拒的控件。
                actions={!reversed ? <ReverseFreightControl id={id} /> : undefined}
            />

            {/* 【空状态要说出它是哪一种空】出境单据没有分摊行,不是"还没有记" ——
                所以这里是一句话,不是一张空表。这个区别转换前就在,没有被压平。 */}
            {outbound ? (
                <>
                    <h2 className="text-lg font-semibold mb-2">{t('finance.freight.outboundNoAllocTitle')}</h2>
                    <p className="text-sm text-gray-600 max-w-3xl">{t('finance.freight.outboundNoAlloc')}</p>
                </>
            ) : (
                <>
                    <h2 className="text-lg font-semibold mb-2">{t('finance.freight.allocTitle')}</h2>
                    <p className="text-sm text-gray-600 mb-3 max-w-3xl">{t('finance.freight.allocHint')}</p>
                    <FreightAllocationsTable rows={tableRows} />
                </>
            )}
        </ListPage>
    )
}
