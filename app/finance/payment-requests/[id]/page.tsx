// app/finance/payment-requests/[id]/page.tsx
// PAY-REQ-1(Tim 2026-09-23):一张付款申请。钱离开之前要先批 ——
//   submitted ──CFO 批准──▶ approved ──财务付款──▶ paid(分录只在这一刻过账)
//       └──驳回(要理由)/ 撤回
// 这一页说清楚【批的是什么】(收款人、金额、要结清的单据),并把三个动作摆在它们
// 适用的那个状态上。谁能批由数据库裁,这里不预判(见 RequestActions 抬头)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { getBaseCurrency } from '@/lib/currency'
import { formatMoneyBare } from '@/lib/format'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader, type RecordField } from '@/app/components/ui/record-header'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import RequestActions from './RequestActions'
import RequestAllocationsTable, { type RequestAllocRow } from './RequestAllocationsTable'

// allocations 的形状与 record_payment 收的那一组相同:每行恰好一个单据键 + amount_doc。
type AllocIn = {
    expense_id?: string
    inbound_batch_id?: string
    purchase_order_id?: string
    freight_document_id?: string
    amount_doc?: number | string
}

// 与 mustOne 的其它调用点同一写法(app/operation/orders/[id]/page.tsx):单行在取用处本地锁死类型。
type RequestRow = {
    id: string; code: string; kind: string; status: string; counterparty_type: string
    supplier_id: string | null; employee_id: string | null; customer_id: string | null
    amount_ccy: number; currency: string; amount_base: number; fx_rate: number | null
    bank_account_code: string | null; planned_date: string | null; allocations: unknown
    payment_id: string | null; notes: string | null
    decided_at: string | null; decided_by: string | null; decision_notes: string | null
    withdrawn_at: string | null; paid_at: string | null; result_payment_id: string | null
    created_at: string
}

export default async function PaymentRequestDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied
    const [canEdit, canDecide] = await Promise.all([can('module.finance.edit'), can('data.view_prices')])

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const baseCurrency = await getBaseCurrency()

    const r = mustOne(
        await supabase
            .from('payment_requests')
            .select('id, code, kind, status, counterparty_type, supplier_id, employee_id, customer_id, amount_ccy, currency, amount_base, fx_rate, bank_account_code, planned_date, allocations, payment_id, notes, decided_at, decided_by, decision_notes, withdrawn_at, paid_at, result_payment_id, created_at')
            .eq('id', id)
            .maybeSingle(),
        'payment request'
    ) as RequestRow | null
    if (!r) notFound()

    // ── 收款人名、原付款(冲销申请)、结果付款(已付)────────────────────────
    type NameRow = { legal_name: string }
    const nameQuery = r.supplier_id
        ? supabase.from('supplier_lookup').select('legal_name').eq('id', r.supplier_id).maybeSingle()
        : r.employee_id
            ? supabase.from('employee_lookup').select('legal_name').eq('id', r.employee_id).maybeSingle()
            : supabase.from('customer_lookup').select('legal_name').eq('id', r.customer_id ?? '').maybeSingle()
    const payIds = [r.payment_id, r.result_payment_id].filter(Boolean) as string[]
    const [nameRes, paymentsRes] = await Promise.all([
        nameQuery,
        payIds.length
            ? supabase.from('payments').select('id, code').in('id', payIds)
            : Promise.resolve({ data: [] as { id: string; code: string }[], error: null }),
    ])
    const payee = (mustOne(nameRes, 'payee name') as unknown as NameRow | null)?.legal_name ?? '—'
    const paymentCode = new Map(mustRows(paymentsRes, 'linked payments').map((p) => [p.id, p.code]))

    // ── 要结清的单据:编号按种类反查(与付款详情页同一套来源)──────────────────
    const allocs: AllocIn[] = Array.isArray(r.allocations) ? (r.allocations as AllocIn[]) : []
    const idsOf = (k: keyof AllocIn) => allocs.map((a) => a[k]).filter(Boolean) as string[]
    const expIds = idsOf('expense_id')
    const batchIds = idsOf('inbound_batch_id')
    const poIds = idsOf('purchase_order_id')
    const frtIds = idsOf('freight_document_id')
    type CodeRow = { id: string; code: string }
    const noneCodes = Promise.resolve({ data: [] as CodeRow[], error: null })
    const [expRes, batchRes, poRes, frtRes] = await Promise.all([
        expIds.length ? supabase.from('expenses').select('id, code').in('id', expIds) : noneCodes,
        // FIX-2a:批次编号走查名视图(基表挂 inbound.view,这一页的门是 finance.view)。
        batchIds.length ? supabase.from('inbound_batch_lookup').select('id, code').in('id', batchIds) : noneCodes,
        poIds.length ? supabase.from('purchase_orders_masked').select('id, code').in('id', poIds) : noneCodes,
        frtIds.length ? supabase.from('freight_documents').select('id, code').in('id', frtIds) : noneCodes,
    ])
    const codeOf = new Map<string, string>()
    for (const res of [expRes, batchRes, poRes, frtRes]) {
        for (const c of mustRows(res, 'allocation document codes') as unknown as CodeRow[]) codeOf.set(c.id, c.code)
    }
    const allocRows: RequestAllocRow[] = allocs.map((a, i) => {
        const [docId, href] =
            a.expense_id ? [a.expense_id, `/finance/expenses/${a.expense_id}`]
            : a.inbound_batch_id ? [a.inbound_batch_id, `/finance/payables/${a.inbound_batch_id}`]
            : a.purchase_order_id ? [a.purchase_order_id, `/purchasing/orders/${a.purchase_order_id}`]
            : a.freight_document_id ? [a.freight_document_id, `/finance/freight/${a.freight_document_id}`]
            : ['', null]
        return {
            id: `${i}:${docId}`,
            // 认不出的种类不给链接、不猜编号 —— 印出 id 本身。
            docCode: codeOf.get(docId) ?? (docId || '—'),
            docHref: href,
            amountText: formatMoneyBare(Number(a.amount_doc ?? 0), '列头 核销额(单据币种)'),
        }
    })

    const isReversal = r.kind === 'payment_reversal'
    const statusClass =
        r.status === 'submitted' ? 'bg-amber-100 text-amber-800'
        : r.status === 'approved' ? 'bg-blue-100 text-blue-800'
        : r.status === 'paid' ? 'bg-green-100 text-green-800'
        : 'bg-gray-200 text-gray-700'

    const fields: RecordField[] = [
        { label: t('finance.colCode'), value: r.code, mono: true },
        { label: t('finance.paymentRequests.colKind'), value: t('finance.paymentRequests.kind.' + r.kind) },
        {
            label: t('finance.colStatus'),
            value: <span className={'px-2 py-1 rounded text-xs ' + statusClass}>{t('finance.paymentRequests.status.' + r.status)}</span>,
        },
        { label: t('finance.paymentRequests.colPayee'), value: payee },
        {
            label: t('finance.amount'),
            value: (
                <>
                    <span className="font-medium">
                        {r.currency} {formatMoneyBare(r.amount_ccy, '同格内紧邻的 r.currency 前缀')}
                    </span>
                    {r.currency !== baseCurrency && (
                        <span className="text-[color:var(--brand-muted-text)] ml-1">
                            ≈ {formatMoneyBare(r.amount_base, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}
                        </span>
                    )}
                </>
            ),
        },
    ]
    if (r.bank_account_code) fields.push({ label: t('finance.bankAccount'), value: t('finance.bank.' + r.bank_account_code) })
    if (r.planned_date) fields.push({ label: t('finance.plannedPaymentDate'), value: formatDate(r.planned_date, locale) })
    if (isReversal && r.payment_id) {
        fields.push({
            label: t('finance.paymentRequests.reversesPayment'),
            value: (
                <Link href={`/finance/payments/${r.payment_id}`} className="hover:underline app-link app-link-inline">
                    {paymentCode.get(r.payment_id) ?? r.payment_id}
                </Link>
            ),
        })
    }
    fields.push({ label: t('finance.paymentRequests.colRaised'), value: formatAuditStamp(r.created_at) })

    return (
        <ListPage
            maxWidth="max-w-4xl"
            breadcrumb={
                <Link href="/finance/payment-requests" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            }
            title={t('finance.paymentRequests.detailTitle')}
            // 详情页恒为 ok —— 记录在不在由 notFound() 回答。
            state={{ kind: 'ok' }}
            notices={
                r.status === 'paid' && r.result_payment_id && r.paid_at ? (
                    <div className="bg-green-50 border border-green-300 text-green-900 px-4 py-3 rounded mb-4 text-sm">
                        <Link href={`/finance/payments/${r.result_payment_id}`} className="hover:underline app-link">
                            {t('finance.paymentRequests.paidAs', {
                                code: paymentCode.get(r.result_payment_id) ?? r.result_payment_id,
                                when: formatAuditStamp(r.paid_at),
                            })}
                        </Link>
                    </div>
                ) : undefined
            }
        >
            <RecordHeader fields={fields} />

            {r.notes && (
                <p className="text-sm mb-4">
                    <span className="text-[color:var(--brand-muted-text)] mr-1">
                        {isReversal ? t('finance.paymentRequests.reversalReason') : t('finance.memo')}:
                    </span>
                    {r.notes}
                </p>
            )}

            {r.currency !== baseCurrency && (
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{t('finance.paymentRequests.baseNote')}</p>
            )}

            {/* ── 决定 ── */}
            {r.decided_at ? (
                <div className="text-sm mb-4 space-y-1">
                    <p>
                        <span className="text-[color:var(--brand-muted-text)] mr-1">{t('finance.paymentRequests.decidedAt')}:</span>
                        {formatAuditStamp(r.decided_at)}
                    </p>
                    {r.decision_notes && (
                        <p>
                            <span className="text-[color:var(--brand-muted-text)] mr-1">{t('finance.paymentRequests.decisionNotes')}:</span>
                            {r.decision_notes}
                        </p>
                    )}
                </div>
            ) : (r.status === 'approved' || r.status === 'paid') ? (
                // 审批关着时申请生下来就是 approved,决定人与时刻皆空 —— 说出来,不画一个空格子。
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.paymentRequests.autoApproved')}</p>
            ) : null}
            {r.withdrawn_at && (
                <p className="text-sm mb-4">
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('finance.paymentRequests.withdrawnAt')}:</span>
                    {formatAuditStamp(r.withdrawn_at)}
                </p>
            )}

            <div className="mb-6">
                <RequestActions
                    requestId={r.id}
                    code={r.code}
                    kind={r.kind}
                    status={r.status}
                    canEdit={canEdit}
                    canDecide={canDecide}
                />
            </div>

            {!isReversal && (
                <>
                    <h2 className="mb-2">{t('finance.paymentRequests.allocTitle')}</h2>
                    <RequestAllocationsTable rows={allocRows} empty={t('finance.paymentRequests.allocEmpty')} />
                </>
            )}
        </ListPage>
    )
}
