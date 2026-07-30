// app/finance/receivables/[saleId]/page.tsx
// AR 单据详情:头部卡(单据号 = 产出批次编号,链批次编辑页;客户/售出日/数量×单价/
// 原币+汇率/USD 金额/已结/未结)+ 结算历史(payment_allocations × payments —— 已冲销
// 收款的核销不计入已结额,但仍然显示为灰色删除线行,保证历史完整)+ 凭据附件面板
// + 关联分录(收入分录 source_type='sale',COGS 经 sales_records.cogs_entry_id)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatUsd } from '@/lib/format'
import Subnav from '../../Subnav'
import FinanceAttachmentsPanel from '@/app/components/finance/FinanceAttachmentsPanel'

type AllocRow = {
    id: string
    allocated_usd: number
    payments: {
        id: string
        code: string
        payment_date: string
        status: string
    } | null
}

export default async function ReceivableDocPage({
    params,
}: {
    params: Promise<{ saleId: string }>
}) {
    const { saleId } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: sale, error } = await supabase
        .from('sales_records')
        .select('id, output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_usd, sale_date, notes, cogs_entry_id')
        .eq('id', saleId)
        .single()

    if (error || !sale) {
        notFound()
    }

    // 批次(单据号+物料)/ 客户 / 结算历史 / 收入分录 / COGS 分录 / 附件,页级小查询
    const [batchRes, customerRes, allocsRes, revenueRes, cogsRes, attachRes, invoiceRes] = await Promise.all([
        supabase
            .from('output_batches')
            .select('id, code, materials(name)')
            .eq('id', sale.output_batch_id)
            .single(),
        sale.customer_id
            ? supabase.from('customers').select('legal_name').eq('id', sale.customer_id).single()
            : Promise.resolve({ data: null }),
        supabase
            .from('payment_allocations')
            .select('id, allocated_usd, payments(id, code, payment_date, status)')
            .eq('sales_record_id', saleId)
            .order('created_at', { ascending: true }),
        supabase
            .from('journal_entries')
            .select('id, code')
            .eq('source_type', 'sale')
            .eq('source_id', saleId)
            .order('created_at', { ascending: true }),
        sale.cogs_entry_id
            ? supabase.from('journal_entries').select('id, code').eq('id', sale.cogs_entry_id).single()
            : Promise.resolve({ data: null }),
        supabase
            .from('finance_attachments')
            .select('id, file_name, file_path, file_size, mime_type, doc_type, notes, created_at')
            .eq('sales_record_id', saleId)
            .is('deleted_at', null)
            .order('created_at', { ascending: false }),
        // 本销售所挂的在册发票(作废的不算)
        supabase
            .from('invoice_lines')
            .select('invoice_id, invoices(id, code)')
            .eq('sales_record_id', saleId)
            .eq('invoice_voided', false)
            .maybeSingle(),
    ])

    const allocs = ((allocsRes.data as unknown as AllocRow[] | null) ?? [])
    const invoice = (invoiceRes.data as unknown as { invoices: { id: string; code: string } | null } | null)?.invoices ?? null

    // 已结额只计 posted 收款的核销(与 ar_open_items 口径一致);reversed 行仍展示。
    const settled =
        Math.round(
            allocs
                .filter((a) => a.payments?.status === 'posted')
                .reduce((s, a) => s + a.allocated_usd, 0) * 100
        ) / 100
    const open = Math.round((sale.amount_usd - settled) * 100) / 100

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端 toLocaleString 引发水合不一致
    const attachments = (attachRes.data ?? []).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_path: a.file_path,
        file_size: a.file_size,
        mime_type: a.mime_type,
        doc_type: a.doc_type,
        notes: a.notes,
        created_at_display: new Date(a.created_at).toLocaleString(dateLocale),
    }))

    const journals = [
        ...(revenueRes.data ?? []),
        ...(cogsRes.data ? [cogsRes.data] : []),
    ]

    const batch = batchRes.data
    const materialName = (batch?.materials as unknown as { name: string } | null)?.name ?? '—'

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/receivables" className="text-blue-600 hover:underline text-sm">
                    {t('finance.backToAging')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('finance.arDocTitle')}</h1>

            <Subnav />

            {/* 头部卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colDocument')}:</span>
                    {batch ? (
                        <Link
                            href={`/output/${batch.id}/edit`}
                            className="text-blue-600 hover:underline font-mono font-medium"
                        >
                            {batch.code}
                        </Link>
                    ) : (
                        <span className="font-mono">—</span>
                    )}
                    <span className="text-gray-500 ml-2">{materialName}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colCounterparty')}:</span>
                    <span>{customerRes.data?.legal_name ?? '—'}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colDate')}:</span>
                    <span>{sale.sale_date}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.amount')}:</span>
                    <span className="font-mono">
                        {sale.quantity} × {sale.unit_price}
                    </span>
                    {sale.currency !== 'USD' && (
                        <span className="text-gray-500 ml-1 font-mono">
                            {sale.currency} @ {sale.fx_rate}
                        </span>
                    )}
                    <span className="font-mono font-medium ml-1">= {formatUsd(sale.amount_usd)} USD</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.settledAmount')}:</span>
                    <span className="font-mono">{formatUsd(settled)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.openAmount')}:</span>
                    <span className="font-mono font-bold">{formatUsd(open)}</span>
                </div>
            </div>

            {sale.notes && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {sale.notes}
                </p>
            )}

            {/* 关联分录:收入分录(source_type='sale')+ COGS(cogs_entry_id)*/}
            {journals.length > 0 && (
                <p className="text-sm mb-4">
                    <span className="text-gray-600 mr-1">{t('finance.relatedJournals')}:</span>
                    {journals.map((j, i) => (
                        <span key={j.id}>
                            {i > 0 && <span className="mx-1 text-gray-300">|</span>}
                            <Link
                                href={`/finance/journal/${j.id}`}
                                className="text-blue-600 hover:underline font-mono"
                            >
                                {j.code}
                            </Link>
                        </span>
                    ))}
                </p>
            )}

            {/* 所属发票 */}
            <p className="text-sm mb-4">
                <span className="text-gray-600 mr-1">{t('invoice.detailTitle')}:</span>
                {invoice ? (
                    <Link
                        href={`/finance/invoices/${invoice.id}`}
                        className="text-blue-600 hover:underline font-mono"
                    >
                        {invoice.code}
                    </Link>
                ) : (
                    <>
                        <span className="text-gray-500">{t('invoice.notInvoiced')}</span>
                        <Link href="/finance/invoices/new" className="text-blue-600 hover:underline ml-2">
                            {t('invoice.new')}
                        </Link>
                    </>
                )}
            </p>

            {/* 结算历史 */}
            <h2 className="text-lg font-semibold mb-3">{t('finance.settlementHistory')}</h2>
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colPayment')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.paymentDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colAllocated')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {allocs.map((a) => {
                        const reversed = a.payments?.status === 'reversed'
                        return (
                            <tr key={a.id} className={reversed ? 'text-gray-400' : ''}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    {a.payments ? (
                                        <Link
                                            href={`/finance/payments/${a.payments.id}`}
                                            className={
                                                reversed
                                                    ? 'text-gray-400 hover:underline line-through'
                                                    : 'text-blue-600 hover:underline'
                                            }
                                        >
                                            {a.payments.code}
                                        </Link>
                                    ) : (
                                        '—'
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {a.payments?.payment_date ?? '—'}
                                </td>
                                <td
                                    className={
                                        'border border-gray-300 px-4 py-2 text-right font-mono text-sm' +
                                        (reversed ? ' line-through' : '')
                                    }
                                >
                                    {formatUsd(a.allocated_usd)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-sm">
                                    {reversed ? (
                                        <span className="px-2 py-1 rounded text-xs bg-gray-200 text-gray-500">
                                            {t('finance.reversedMark')}
                                        </span>
                                    ) : (
                                        <span className="px-2 py-1 rounded text-xs bg-green-100 text-green-800">
                                            {t('finance.status.posted')}
                                        </span>
                                    )}
                                </td>
                            </tr>
                        )
                    })}
                    {allocs.length === 0 && (
                        <tr>
                            <td colSpan={4} className="border border-gray-300 px-4 py-4 text-center text-gray-500 text-sm">
                                {t('finance.noOpenItems')}
                            </td>
                        </tr>
                    )}
                </tbody>
                {allocs.length > 0 && (
                    <tfoot>
                        <tr className="bg-gray-100 font-bold">
                            <td className="border border-gray-300 px-4 py-2" colSpan={2}>
                                {t('finance.settledAmount')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatUsd(settled)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2" />
                        </tr>
                    </tfoot>
                )}
            </table>

            {/* 凭据附件 */}
            <FinanceAttachmentsPanel parent={{ kind: 'sale', id: sale.id }} rows={attachments} />
        </div>
    )
}
