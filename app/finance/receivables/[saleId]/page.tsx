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
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import SettlementHistoryTable, { type SettlementRow } from '@/app/components/finance/SettlementHistoryTable'

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
            // FIX-2a:output_batches 挂 module.output.view,这一页的守卫是 finance.view。
            // cfo 读回零行 —— 应收明细页说不出这笔钱卖的是哪一批。物料名单独取
            // (内嵌会对 materials 另套一遍 RLS)。
            .from('output_batch_lookup')
            .select('id, code, material_id')
            .eq('id', sale.output_batch_id)
            .single(),
        sale.customer_id
            ? supabase.from('customer_lookup').select('legal_name').eq('id', sale.customer_id).single()
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
    const materialName = batch?.material_id
        ? (await supabase.from('material_lookup').select('name').eq('id', batch.material_id).maybeSingle())
              .data?.name ?? '—'
        : '—'

    // SAL-C:无主销售才需要补挂控件 —— 有主的看不到这条路(单向)
    const attributable = sale.customer_id === null
    const customerOptions = attributable
        ? mustRows(
              await supabase
                  .from('customer_lookup')
                  .select('id, code, legal_name')
                  .is('deleted_at', null)
                  .order('code')
          ) as unknown as { id: string; code: string; legal_name: string }[]
        : []


    // ★【行数据在服务端压平】金额格式要 baseCurrency(CONV-1 §①)。
    //   这张表与 /finance/payables/[batchId] 的【是同一张】—— 组件住在
    //   app/components/finance/,理由写在它的抬头。
    const tableRows: SettlementRow[] = allocs.map((a) => ({
        id: a.id,
        paymentCode: a.payments?.code ?? '—',
        paymentHref: a.payments ? `/finance/payments/${a.payments.id}` : null,
        paymentDate: a.payments?.payment_date ?? '—',
        allocatedText: formatAmount(a.allocated_base, baseCurrency),
        reversed: a.payments?.status === 'reversed',
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    if (tableRows.length > 0) {
        tableRows.push({
            id: '__total__',
            paymentCode: t('finance.settledAmount'),
            paymentHref: null,
            paymentDate: '',
            allocatedText: formatAmount(settled, baseCurrency),
            reversed: false,
            isTotal: true,
        })
    }

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={
                <Link href="/finance/receivables" className="text-blue-600 hover:underline text-sm">
                    {t('finance.backToAging')}
                </Link>
            }
            title={t('finance.arDocTitle')}
            // ★★ 详情页恒为 ok —— 这笔销售在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一块 bg-gray-50 的面板。
                这一页的记录级动作是【补挂客户】,而它只在无主时存在;
                它是一整块带说明的面板,不是一枚按钮,所以留在 children 里
                (见下面那一段),不塞进 actions 槽。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('finance.colDocument'),
                        value: (
                            <>
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
                            </>
                        ),
                    },
                    { label: t('finance.colCounterparty'), value: customerRes.data?.legal_name ?? '—' },
                    { label: t('finance.colDate'), value: sale.sale_date },
                    {
                        label: t('finance.amount'),
                        value: (
                            <>
                                <span className="font-mono">
                                    {sale.quantity} × {sale.unit_price}
                                </span>
                                {sale.currency !== baseCurrency && (
                                    <span className="text-gray-500 ml-1 font-mono">
                                        {sale.currency} @ {sale.fx_rate}
                                    </span>
                                )}
                                <span className="font-mono font-medium ml-1">
                                    = {formatMoneyBare(sale.amount_base, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}
                                </span>
                            </>
                        ),
                    },
                    { label: t('finance.settledAmount'), value: formatAmount(settled, baseCurrency), mono: true },
                    {
                        label: t('finance.openAmount'),
                        value: <span className="font-bold">{formatAmount(open, baseCurrency)}</span>,
                        mono: true,
                    },
                ]}
            />

            {/* SAL-C:这笔销售【不属于任何人】—— 说清楚,并给出补挂的路。
                走查里 INV-2026-0005 就是把这样一笔销售开给了客户:发票声称有人欠钱,
                而销售没有记录,敞口也看不见它。
                ★ 出口检查:这是这一页的记录级出口,住在 children 里;详情页 state
                  恒为 'ok',children 永远画,所以它不可能被空分支吃掉。 */}
            {attributable && (
                <div className="mb-6">
                    <AttributeCustomerControl saleId={sale.id} subject={batch ? `${batch.code} · ${sale.sale_date}` : sale.sale_date} customers={customerOptions} />
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

            {/* 所属发票 —— 未开票时这里是第二个出口(去开一张) */}
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
            <SettlementHistoryTable rows={tableRows} />

            {/* 凭据附件 */}
            <FinanceAttachmentsPanel parent={{ kind: 'sale', id: sale.id }} rows={attachments} />
        </ListPage>
    )
}
