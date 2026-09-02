// app/finance/receivables/[saleId]/page.tsx
// AR 单据详情:头部卡(单据号 = 产出批次编号,链批次编辑页;客户/售出日/数量×单价/
// 原币+汇率/USD 金额/已结/未结)+ 结算历史(payment_allocations × payments —— 已冲销
// 收款的核销不计入已结额,但仍然显示为灰色删除线行,保证历史完整)+ 凭据附件面板
// + 关联分录(收入分录 source_type='sale',COGS 经 sales_records.cogs_entry_id)。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatAmount, formatMoneyBare, formatTimestamp } from '@/lib/format'
import AttributeCustomerControl from './AttributeCustomerControl'
import FinanceAttachmentsPanel from '@/app/components/finance/FinanceAttachmentsPanel'
import { unmasked } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type AllocRow = {
    id: string
    allocated_base: number
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
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const { saleId } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: saleRaw, error } = await supabase
        .from('sales_records_masked')
        .select('id, output_batch_id, customer_id, quantity, unit_price, currency, fx_rate, amount_base, sale_date, notes, cogs_entry_id')
        .eq('id', saleId)
        .single()

    if (error || !saleRaw) {
        notFound()
    }

    // cut 2b:改读遮蔽视图(基表的原始敏感列已被收回)。这里断言回基表行类型 ——
    // 能进到这个页面的角色(admin / finance / auditor)全都持有 data.view_prices,
    // 所以这些列不会被遮蔽。理由与失效条件见 lib/maskedRows.ts。
    const sale = unmasked<Tables<'sales_records'>>(saleRaw)

    // 批次(单据号+物料)/ 客户 / 结算历史 / 收入分录 / COGS 分录 / 附件,页级小查询
    const [batchRes, customerRes, allocsRes, revenueRes, cogsRes, attachRes, invoiceRes] = await Promise.all([
        supabase
            .from('output_batches')
            .select('id, code, materials(name)')
            .eq('id', sale.output_batch_id)
            .single(),
        sale.customer_id
            ? supabase.from('customers').select('legal_name').eq('id', sale.customer_id).single()
            : Promise.resolve({ data: null, error: null }),
        supabase
            .from('payment_allocations')
            .select('id, allocated_base, payments(id, code, payment_date, status)')
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
            : Promise.resolve({ data: null, error: null }),
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
                .reduce((s, a) => s + a.allocated_base, 0) * 100
        ) / 100
    const open = Math.round((sale.amount_base - settled) * 100) / 100

    // 在服务端按当前语言格式化时间,再传给客户端面板 —— 避免客户端 toLocaleString 引发水合不一致
    const attachments = (mustRows(attachRes)).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_path: a.file_path,
        file_size: a.file_size,
        mime_type: a.mime_type,
        doc_type: a.doc_type,
        notes: a.notes,
        created_at_display: formatTimestamp(a.created_at, dateLocale),
    }))

    const journals = [
        ...(mustRows(revenueRes)),
        ...(cogsRes.data ? [cogsRes.data] : []),
    ]

    const batch = batchRes.data
    const materialName = (batch?.materials as unknown as { name: string } | null)?.name ?? '—'

    // SAL-C:无主销售才需要补挂控件 —— 有主的看不到这条路(单向)
    const attributable = sale.customer_id === null
    const customerOptions = attributable
        ? mustRows(
              await supabase
                  .from('customers')
                  .select('id, code, legal_name')
                  .is('deleted_at', null)
                  .order('code')
          )
        : []

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/receivables" className="text-blue-600 hover:underline text-sm">
                    {t('finance.backToAging')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('finance.arDocTitle')}</h1>

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
                    {sale.currency !== baseCurrency && (
                        <span className="text-gray-500 ml-1 font-mono">
                            {sale.currency} @ {sale.fx_rate}
                        </span>
                    )}
                    <span className="font-mono font-medium ml-1">= {formatMoneyBare(sale.amount_base, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.settledAmount')}:</span>
                    <span className="font-mono">{formatAmount(settled, baseCurrency)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.openAmount')}:</span>
                    <span className="font-mono font-bold">{formatAmount(open, baseCurrency)}</span>
                </div>
            </div>

            {/* SAL-C:这笔销售【不属于任何人】—— 说清楚,并给出补挂的路。
                走查里 INV-2026-0005 就是把这样一笔销售开给了客户:发票声称有人欠钱,
                而销售没有记录,敞口也看不见它。 */}
            {attributable && (
                <div className="mb-6">
                    <AttributeCustomerControl saleId={sale.id} customers={customerOptions} />
                </div>
            )}

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
                                    {formatAmount(a.allocated_base, baseCurrency)}
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
                                {formatAmount(settled, baseCurrency)}
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
