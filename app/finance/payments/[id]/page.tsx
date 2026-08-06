// app/finance/payments/[id]/page.tsx
// 收付款详情:头部(编号/日期/方向/往来单位/金额原币+USD+汇率/银行/状态/备注)
// + 关联分录链接 + 核销行表(单据链接 + 冲销额)+ 未冲销余额行。
// posted → 冲销按钮;reversed → "已被 X 冲销"横幅(链到镜像单)。
// 核销行表下方:凭据附件面板(finance_attachments, parent kind 'payment')。
import Link from 'next/link'
import { getBaseCurrency } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoney, formatAmount, formatTimestamp } from '@/lib/format'
import Subnav from '../../Subnav'
import ReversePaymentButton from './ReversePaymentButton'
import FinanceAttachmentsPanel from '@/app/components/finance/FinanceAttachmentsPanel'
import { mustRows } from '@/lib/db-helpers'

type AllocRow = {
    id: string
    sales_record_id: string | null
    inbound_batch_id: string | null
    expense_id: string | null
    purchase_order_id: string | null
    allocated_base: number
    // FIN-18:这条核销消耗掉的【付款币种】金额 —— 挂账余额只能由它算
    allocated_pay: number
    allocated_ccy: number
}

export default async function PaymentDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: payment, error } = await supabase
        .from('payments')
        .select('id, code, direction, customer_id, supplier_id, amount_ccy, currency, fx_rate, amount_base, bank_account_code, payment_date, notes, journal_entry_id, status, reversed_by_payment')
        .eq('id', id)
        .single()

    if (error || !payment) {
        notFound()
    }

    // 往来单位名 / 关联分录 / 核销行 / 镜像单,页级小查询
    const [partyRes, journalRes, allocsRes, reversedByRes] = await Promise.all([
        payment.direction === 'in'
            ? supabase.from('customers').select('legal_name').eq('id', payment.customer_id ?? '').single()
            : supabase.from('suppliers').select('legal_name').eq('id', payment.supplier_id ?? '').single(),
        payment.journal_entry_id
            ? supabase.from('journal_entries').select('id, code').eq('id', payment.journal_entry_id).single()
            : Promise.resolve({ data: null, error: null }),
        supabase
            .from('payment_allocations')
            .select('id, sales_record_id, inbound_batch_id, expense_id, purchase_order_id, allocated_base, allocated_pay, allocated_ccy')
            .eq('payment_id', id)
            .order('created_at', { ascending: true }),
        payment.reversed_by_payment
            ? supabase.from('payments').select('id, code').eq('id', payment.reversed_by_payment).single()
            : Promise.resolve({ data: null, error: null }),
    ])

    const allocs = ((allocsRes.data as AllocRow[] | null) ?? [])

    // 核销单据:AR 经 sales_record → output_batch 反查编号/链接,AP 直查进料批次/开支单;
    // 预付行(cut 4b)查采购单编号
    const saleIds = allocs.map((a) => a.sales_record_id).filter(Boolean) as string[]
    const batchIds = allocs.map((a) => a.inbound_batch_id).filter(Boolean) as string[]
    const expenseIds = allocs.map((a) => a.expense_id).filter(Boolean) as string[]
    const poIds = allocs.map((a) => a.purchase_order_id).filter(Boolean) as string[]
    const [salesRes, inboundRes, expensesRes, poRes] = await Promise.all([
        saleIds.length
            ? supabase.from('sales_records').select('id, output_batch_id').in('id', saleIds)
            : Promise.resolve({ data: [] as { id: string; output_batch_id: string }[], error: null }),
        batchIds.length
            ? supabase.from('inbound_batches').select('id, code').in('id', batchIds)
            : Promise.resolve({ data: [] as { id: string; code: string }[], error: null }),
        expenseIds.length
            ? supabase.from('expenses').select('id, code').in('id', expenseIds)
            : Promise.resolve({ data: [] as { id: string; code: string }[], error: null }),
        poIds.length
            ? supabase.from('purchase_orders').select('id, code').in('id', poIds)
            : Promise.resolve({ data: [] as { id: string; code: string }[], error: null }),
    ])
    const outputBySale = new Map((mustRows(salesRes)).map((s) => [s.id, s.output_batch_id]))
    const outputIds = Array.from(new Set(Array.from(outputBySale.values())))
    const { data: outputBatches } = outputIds.length
        ? await supabase.from('output_batches').select('id, code').in('id', outputIds)
        : { data: [] as { id: string; code: string }[] }
    const outputCodeById = new Map((outputBatches ?? []).map((b) => [b.id, b.code]))
    const inboundById = new Map((mustRows(inboundRes)).map((b) => [b.id, b.code]))
    const expenseById = new Map((mustRows(expensesRes)).map((e) => [e.id, e.code]))
    const poById = new Map((mustRows(poRes)).map((p) => [p.id, p.code]))

    // 每行核销的单据编号 + 链接
    const allocDoc = (a: AllocRow): { code: string; href: string | null } => {
        if (a.sales_record_id) {
            const batchId = outputBySale.get(a.sales_record_id)
            return {
                code: (batchId && outputCodeById.get(batchId)) ?? '—',
                href: batchId ? `/output/${batchId}/edit` : null,
            }
        }
        if (a.expense_id) {
            return {
                code: expenseById.get(a.expense_id) ?? '—',
                href: `/finance/expenses/${a.expense_id}`,
            }
        }
        if (a.purchase_order_id) {
            // 预付行:指向采购单(还没有单据可核销的钱,躺在 1300 里)
            return {
                code: poById.get(a.purchase_order_id) ?? '—',
                href: `/purchasing/orders/${a.purchase_order_id}`,
            }
        }
        return {
            code: inboundById.get(a.inbound_batch_id ?? '') ?? '—',
            href: a.inbound_batch_id ? `/inbound/${a.inbound_batch_id}/edit` : null,
        }
    }

    const allocTotal = Math.round(allocs.reduce((s, a) => s + a.allocated_base, 0) * 100) / 100
    // ════════════════════════════════════════════════════════════════════════
    // 【挂账余额在付款币种空间算 —— FIN-18】原式是
    //     payment.amount_base − Σ allocated_base
    // 两个数同为本位币,却不是同一个汇率:amount_base 按结算日汇率,
    // allocated_base 按各单据的入账汇率。差额正是记进 7100 的已实现汇兑,于是
    // 一笔全额核销的外币收付款只要汇率动过就显示出一笔并不存在的挂账
    //(线上 PMT-2026-0003 显示 6.08,实为 0)。
    // allocated_pay 是 record_payment 落库的【消耗掉的付款额】,与 amount_ccy
    // 同币种同口径 —— 相减才有意义。
    // ════════════════════════════════════════════════════════════════════════
    const consumedPay = Math.round(allocs.reduce((s, a) => s + a.allocated_pay, 0) * 100) / 100
    const unallocated = Math.round((payment.amount_ccy - consumedPay) * 100) / 100
    const partyName = partyRes.data?.legal_name ?? '—'

    // 凭据附件(在服务端按当前语言格式化时间,避免客户端水合不一致)
    const { data: attachmentRows } = await supabase
        .from('finance_attachments')
        .select('id, file_name, file_path, file_size, mime_type, doc_type, notes, created_at')
        .eq('payment_id', id)
        .is('deleted_at', null)
        .order('created_at', { ascending: false })
    const attachments = (attachmentRows ?? []).map((a) => ({
        id: a.id,
        file_name: a.file_name,
        file_path: a.file_path,
        file_size: a.file_size,
        mime_type: a.mime_type,
        doc_type: a.doc_type,
        notes: a.notes,
        created_at_display: formatTimestamp(a.created_at, dateLocale),
    }))

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/payments" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('finance.paymentsTitle')}</h1>

            <Subnav />

            {/* 冲销横幅 */}
            {payment.status === 'reversed' && reversedByRes.data && (
                <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                    <Link
                        href={`/finance/payments/${reversedByRes.data.id}`}
                        className="text-blue-600 hover:underline"
                    >
                        {t('finance.reversedByPayment', { code: reversedByRes.data.code })}
                    </Link>
                </div>
            )}

            {/* 头部 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colCode')}:</span>
                    <span className="font-mono font-medium">{payment.code}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.paymentDate')}:</span>
                    <span>{payment.payment_date}</span>
                </div>
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (payment.direction === 'in'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {t('finance.direction.' + payment.direction)}
                    </span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colCounterparty')}:</span>
                    <span>{partyName}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.amount')}:</span>
                    <span className="font-mono font-medium">
                        {payment.currency} {formatMoney(payment.amount_ccy)}
                    </span>
                    {payment.currency !== baseCurrency && (
                        <span className="text-gray-500 ml-1 font-mono">
                            @ {payment.fx_rate} = {formatMoney(payment.amount_base)} {baseCurrency}
                        </span>
                    )}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.bankAccount')}:</span>
                    <span>{t('finance.bank.' + payment.bank_account_code)}</span>
                </div>
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (payment.status === 'posted'
                                ? 'bg-green-100 text-green-800'
                                : 'bg-gray-200 text-gray-700')
                        }
                    >
                        {t('finance.status.' + payment.status)}
                    </span>
                </div>
                {payment.status === 'posted' && <ReversePaymentButton paymentId={payment.id} />}
            </div>

            {payment.notes && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {payment.notes}
                </p>
            )}

            {/* 关联分录 */}
            {journalRes.data && (
                <p className="text-sm mb-4">
                    <span className="text-gray-600 mr-1">{t('finance.linkedJournal')}:</span>
                    <Link
                        href={`/finance/journal/${journalRes.data.id}`}
                        className="text-blue-600 hover:underline font-mono"
                    >
                        {journalRes.data.code}
                    </Link>
                </p>
            )}

            {/* 核销行 */}
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colDocument')}</th>
                        {/* 两列都要带单位:左边是解除的应收/应付(本位币,按单据入账汇率),
                            右边是这条核销吃掉的款额(付款币种)。跨币种时它们不是一个数,
                            差额就是已实现汇兑 —— 摆在一起,那笔差额才解释得清。 */}
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.totalAllocated')} ({baseCurrency})</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.consumedPay')} ({payment.currency})</th>
                    </tr>
                </thead>
                <tbody>
                    {allocs.map((a) => {
                        const doc = allocDoc(a)
                        return (
                            <tr key={a.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    {doc.href ? (
                                        <Link href={doc.href} className="text-blue-600 hover:underline">
                                            {doc.code}
                                        </Link>
                                    ) : (
                                        doc.code
                                    )}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoney(a.allocated_base)}
                                </td>
                                <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                    {formatMoney(a.allocated_pay)}
                                </td>
                            </tr>
                        )
                    })}
                    {allocs.length === 0 && (
                        <tr>
                            <td colSpan={3} className="border border-gray-300 px-4 py-4 text-center text-gray-500 text-sm">
                                {t('finance.unallocated')}
                            </td>
                        </tr>
                    )}
                </tbody>
                {allocs.length > 0 && (
                    <tfoot>
                        <tr className="bg-gray-100 font-bold">
                            <td className="border border-gray-300 px-4 py-2">{t('finance.totalsLabel')}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatMoney(allocTotal)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatMoney(consumedPay)}
                            </td>
                        </tr>
                    </tfoot>
                )}
            </table>

            {/* 未冲销余额(挂账)*/}
            {unallocated > 0 && (
                <p className="text-sm text-gray-500 mt-3">
                    {t('finance.unallocated')}: <span className="font-mono">{formatAmount(unallocated, payment.currency)}</span>
                </p>
            )}

            {/* 凭据附件 */}
            <FinanceAttachmentsPanel parent={{ kind: 'payment', id: payment.id }} rows={attachments} />
        </div>
    )
}
