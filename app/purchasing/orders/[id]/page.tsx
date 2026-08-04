// app/purchasing/orders/[id]/page.tsx
// 采购单详情:头卡(供应商/日期/币种/状态/审批)+ 明细行(含预计化验)+
// 付款计划(比例期按估算总额折成钱)+ 预付摘要(已付/已抵扣/未抵扣 → 登记付款入口)+
// 收货记录(关联进料批次、已收 vs 下单量)+ 取消(无收货且无已抵扣预付才允许)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoney, formatUnitCost } from '@/lib/format'
import Subnav from '../../Subnav'
import CancelOrderControl from './CancelOrderControl'
import { CloseOrderControl, ReopenOrderControl } from './CloseReopenControls'
import { canViewPrices } from '@/lib/permissions'
import { maskedExcept, maskedRows } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'

type AssayEntry = { metal: string; content_pct: number }

const round2 = (n: number) => Math.round(n * 100) / 100

export default async function PurchaseOrderDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: poRaw, error } = await supabase
        .from('purchase_orders_masked')
        .select('id, code, supplier_id, order_date, expected_delivery_date, currency, fx_rate, estimated_total_usd, status, approval_status, incoterm, terms_text, notes, cancelled_at, cancel_reason')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !poRaw) {
        notFound()
    }

    // cut 2b:改读遮蔽视图。fx_rate / estimated_total_usd 会被遮蔽(没有 data.view_prices
    // 时为 null),其余列恢复基表类型 —— 视图带来的"人人可空"只是类型噪音。
    const showPrices = await canViewPrices()
    const po = maskedExcept<Tables<'purchase_orders'>, 'fx_rate' | 'estimated_total_usd'>(poRaw)

    const [supplierRes, linesRes, termsRes, statusRes, receiptsRes] = await Promise.all([
        supabase.from('suppliers').select('id, legal_name').eq('id', po.supplier_id).single(),
        supabase
            .from('purchase_order_lines_masked')
            .select('id, line_no, material_id, quantity, unit, pricing_formula_id, estimated_unit_price, estimated_amount_usd, expected_assay, notes')
            .eq('purchase_order_id', id)
            .order('line_no'),
        supabase
            .from('purchase_order_payment_terms_masked')
            .select('seq, label, percentage, fixed_amount_usd, trigger_event, due_date')
            .eq('purchase_order_id', id)
            .order('seq'),
        // 已取消的单不在视图里 → 预付/进度区不展示
        supabase.from('purchase_order_status').select('*').eq('po_id', id).maybeSingle(),
        supabase
            .from('inbound_batches_masked')
            .select('id, code, arrival_date, quantity, unit, unit_price')
            .eq('purchase_order_id', id)
            .is('deleted_at', null)
            .order('created_at'),
    ])

    // 遮蔽的是估价列;material_id / pricing_formula_id 等恢复基表类型。
    const lines = maskedRows<Tables<'purchase_order_lines'>, 'estimated_unit_price' | 'estimated_amount_usd'>(linesRes.data)
    const terms = maskedRows<Tables<'purchase_order_payment_terms'>, 'fixed_amount_usd'>(termsRes.data)
    const poStatus = statusRes.data
    const receipts = maskedRows<Tables<'inbound_batches'>, 'unit_price'>(receiptsRes.data)

    // 物料/公式名 + 收货批次的未结应付(结清的批次不在 ap_open_items → 敞口 0)
    const materialIds = Array.from(new Set(lines.map((l) => l.material_id)))
    const formulaIds = Array.from(new Set(lines.map((l) => l.pricing_formula_id).filter(Boolean))) as string[]
    const batchIds = receipts.map((r) => r.id)
    const [materialsRes, formulasRes, apRes] = await Promise.all([
        materialIds.length
            ? supabase.from('materials').select('id, code, name').in('id', materialIds)
            : Promise.resolve({ data: [] as { id: string; code: string; name: string }[] }),
        formulaIds.length
            ? supabase.from('pricing_formulas').select('id, code, name').in('id', formulaIds)
            : Promise.resolve({ data: [] as { id: string; code: string; name: string }[] }),
        batchIds.length
            ? supabase.from('ap_open_items').select('inbound_batch_id, open_base').in('inbound_batch_id', batchIds)
            : Promise.resolve({ data: [] as { inbound_batch_id: string | null; open_base: number }[] }),
    ])
    const materialById = new Map((materialsRes.data ?? []).map((m) => [m.id, `${m.code} — ${m.name}`]))
    const formulaById = new Map((formulasRes.data ?? []).map((f) => [f.id, `${f.code} — ${f.name}`]))
    const openByBatch = new Map((apRes.data ?? []).map((r) => [r.inbound_batch_id ?? '', r.open_base]))

    // 每批已抵扣的预付(cut 4c:收货记录多一列)
    const { data: appliedRows } = batchIds.length
        ? await supabase
              .from('prepayment_applications_masked')
              .select('inbound_batch_id, amount_base')
              .in('inbound_batch_id', batchIds)
        : { data: [] as { inbound_batch_id: string; amount_base: number }[] }
    const appliedByBatch = new Map<string, number>()
    for (const r of maskedRows<Tables<'prepayment_applications'>, 'amount_base'>(appliedRows)) {
        appliedByBatch.set(r.inbound_batch_id, round2((appliedByBatch.get(r.inbound_batch_id) ?? 0) + Number(r.amount_base)))
    }

    const isCancelled = po.status === 'cancelled'
    const receivedQty = poStatus?.received_qty ?? receipts.reduce((s, r) => s + Number(r.quantity), 0)
    const orderedQty = poStatus?.ordered_qty ?? lines.reduce((s, l) => s + Number(l.quantity), 0)
    const appliedUsd = Number(poStatus?.prepaid_applied_base ?? 0)
    // 取消的前置条件与 DB 的 cancel_purchase_order 一致:无收货、无已抵扣预付
    const cancelBlocked = receipts.length > 0 || appliedUsd > 0

    const assayInline = (assay: unknown): string => {
        if (!Array.isArray(assay) || assay.length === 0) return ''
        return (assay as AssayEntry[])
            .map((a) => `${t('metals.' + a.metal)} ${a.content_pct}%`)
            .join(' · ')
    }

    const termAmount = (l: { percentage: number | null; fixed_amount_usd: number | null }) =>
        l.percentage !== null
            ? round2((Number(po.estimated_total_usd) * l.percentage) / 100)
            : Number(l.fixed_amount_usd ?? 0)

    const statusPill = (
        <span
            className={
                'px-2 py-1 rounded text-xs ' +
                (po.status === 'confirmed' || po.status === 'receiving'
                    ? 'bg-green-100 text-green-800'
                    : po.status === 'closed'
                      ? 'bg-gray-200 text-gray-700'
                      : po.status === 'cancelled'
                        ? 'bg-red-100 text-red-700'
                        : 'bg-amber-100 text-amber-800')
            }
        >
            {t('purchasing.status.' + po.status)}
        </span>
    )

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/purchasing/orders" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-start mb-2 gap-4">
                <h1 className="text-2xl font-bold">
                    {t('purchasing.orderDetailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">{po.code}</span>
                </h1>
                <div className="flex flex-wrap items-center gap-3 justify-end">
                    {/* 按此单收货:只在可收货状态出现 */}
                    {(po.status === 'confirmed' || po.status === 'receiving') && (
                        <Link
                            href={`/inbound/new?po=${po.id}`}
                            className="bg-blue-600 text-white px-3 py-1.5 rounded hover:bg-blue-700 text-sm"
                        >
                            {t('purchasing.receiveAgainst')}
                        </Link>
                    )}
                    {(po.status === 'confirmed' || po.status === 'receiving') && (
                        <CloseOrderControl
                            poId={po.id}
                            unappliedPrepayment={Number(poStatus?.prepaid_remaining_base ?? 0)}
                        />
                    )}
                    {po.status === 'closed' && <ReopenOrderControl poId={po.id} />}
                    {!isCancelled &&
                        po.status !== 'closed' &&
                        (cancelBlocked ? (
                            <p className="text-sm text-gray-400">{t('purchasing.cancelBlocked')}</p>
                        ) : (
                            <CancelOrderControl poId={po.id} />
                        ))}
                </div>
            </div>

            <Subnav />

            {isCancelled && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded mb-4 text-sm">
                    {t('purchasing.status.cancelled')}
                    {po.cancelled_at ? ` · ${po.cancelled_at.slice(0, 10)}` : ''}
                    {po.cancel_reason ? `:${po.cancel_reason}` : ''}
                </div>
            )}

            {/* 头卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colSupplier')}:</span>
                    <Link
                        href={`/suppliers/${po.supplier_id}/edit`}
                        className="text-blue-600 hover:underline"
                    >
                        {supplierRes.data?.legal_name ?? '—'}
                    </Link>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colOrderDate')}:</span>
                    <span>{po.order_date}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colExpectedDelivery')}:</span>
                    <span>{po.expected_delivery_date ?? '—'}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.form.currency')}:</span>
                    <span className="font-mono">
                        {po.currency}
                        {po.currency !== 'SGD' && ` @ ${po.fx_rate}`}
                    </span>
                </div>
                {po.incoterm && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('purchasing.form.incoterm')}:</span>
                        <span>{po.incoterm}</span>
                    </div>
                )}
                <div>{statusPill}</div>
                <div>
                    <span className="text-gray-600 mr-1">{t('purchasing.colEstimatedTotal')}:</span>
                    <span className="font-mono font-medium">{formatMoney(po.estimated_total_usd)}</span>
                </div>
            </div>

            {/* 审批:结构在,流程未启用 */}
            <p className="text-xs text-gray-400 mb-4">
                {t('purchasing.approvalNote')}
                <span className="ml-2 px-2 py-0.5 rounded bg-gray-100 text-gray-500">
                    {po.approval_status}
                </span>
            </p>

            {po.notes && (
                <p className="text-sm text-gray-600 mb-2">
                    <span className="text-gray-500 mr-1">{t('purchasing.form.notes')}:</span>
                    {po.notes}
                </p>
            )}
            {po.terms_text && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('purchasing.form.termsText')}:</span>
                    {po.terms_text}
                </p>
            )}

            {/* 明细行 */}
            <h2 className="text-xl font-bold mb-3">{t('purchasing.form.lines')}</h2>
            <table className="w-full border-collapse border border-gray-300 mb-6">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left w-10">#</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colMaterial')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colQuantity')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colFormula')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colUnitPrice')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colAmount')}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => (
                        <tr key={l.id}>
                            <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{l.line_no}</td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {materialById.get(l.material_id) ?? '—'}
                                {assayInline(l.expected_assay) && (
                                    <span className="block text-xs text-gray-500 mt-0.5">
                                        {t('purchasing.form.expectedAssay')}: {assayInline(l.expected_assay)}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {Number(l.quantity)} {l.unit}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-sm">
                                {l.pricing_formula_id ? (formulaById.get(l.pricing_formula_id) ?? '—') : '—'}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {l.estimated_unit_price !== null ? formatUnitCost(l.estimated_unit_price) : '—'}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                {formatMoney(l.estimated_amount_usd)}
                            </td>
                        </tr>
                    ))}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td colSpan={5} className="border border-gray-300 px-3 py-2 text-right">
                            {t('purchasing.colEstimatedTotal')}
                        </td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                            {formatMoney(po.estimated_total_usd)}
                        </td>
                    </tr>
                </tfoot>
            </table>

            {/* 付款计划 + 预付摘要 */}
            <div className="grid gap-6 md:grid-cols-3 mb-6">
                <div className="md:col-span-2">
                    <h2 className="text-xl font-bold mb-3">{t('purchasing.form.paymentTerms')}</h2>
                    {terms.length > 0 ? (
                        <table className="w-full border-collapse border border-gray-300">
                            <thead className="bg-gray-100">
                                <tr>
                                    <th className="border border-gray-300 px-3 py-2 text-left w-10">{t('purchasing.colSeq')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colLabel')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colShare')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-right">{t('purchasing.colAmount')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colTrigger')}</th>
                                    <th className="border border-gray-300 px-3 py-2 text-left">{t('purchasing.colDueDate')}</th>
                                </tr>
                            </thead>
                            <tbody>
                                {terms.map((l) => (
                                    <tr key={l.seq}>
                                        <td className="border border-gray-300 px-3 py-2 text-sm text-gray-500">{l.seq}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">{l.label}</td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                            {l.percentage !== null
                                                ? `${l.percentage}%`
                                                : `${formatMoney(l.fixed_amount_usd)} USD`}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-right font-mono text-sm">
                                            {formatMoney(termAmount(l))}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">
                                            {t('purchasing.trigger.' + l.trigger_event)}
                                        </td>
                                        <td className="border border-gray-300 px-3 py-2 text-sm">{l.due_date ?? '—'}</td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    ) : (
                        <p className="text-sm text-gray-500">—</p>
                    )}
                </div>

                {poStatus && (
                    <div className="border border-gray-300 rounded p-4 text-sm space-y-2 h-fit">
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('purchasing.prepaidLabel')}</span>
                            <span className="font-mono">{formatMoney(poStatus.prepaid_base)}</span>
                        </div>
                        <div className="flex justify-between">
                            <span className="text-gray-600">{t('purchasing.appliedLabel')}</span>
                            <span className="font-mono">{formatMoney(poStatus.prepaid_applied_base)}</span>
                        </div>
                        <div className="flex justify-between font-medium border-t pt-2">
                            <span>{t('purchasing.remainingLabel')}</span>
                            <span className="font-mono">{formatMoney(poStatus.prepaid_remaining_base)}</span>
                        </div>
                        {!isCancelled && (
                            <Link
                                href={`/finance/payments/new?direction=out&supplier=${po.supplier_id}`}
                                className="block text-center border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-blue-600"
                            >
                                {t('purchasing.payDeposit')}
                            </Link>
                        )}
                    </div>
                )}
            </div>

            {/* 收货记录 */}
            <h2 className="text-xl font-bold mb-3">{t('purchasing.receipts')}</h2>
            {receipts.length > 0 ? (
                <>
                    <p className="text-sm text-gray-600 mb-2">
                        {t('purchasing.receivedVsOrdered', {
                            received: receivedQty,
                            ordered: orderedQty,
                            unit: lines[0]?.unit ?? 'kg',
                        })}
                        {poStatus?.receipt_pct !== null && poStatus?.receipt_pct !== undefined && (
                            <span className="ml-2 font-mono">({poStatus.receipt_pct}%)</span>
                        )}
                    </p>
                    <table className="w-full border-collapse border border-gray-300">
                        <thead className="bg-gray-100">
                            <tr>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-left">{t('inbound.form.arrivalDate')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colQuantity')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colUnitPrice')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.appliedLabel')}</th>
                                <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colOpen')}</th>
                            </tr>
                        </thead>
                        <tbody>
                            {receipts.map((r) => (
                                <tr key={r.id}>
                                    <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                        <Link href={`/inbound/${r.id}/edit`} className="text-blue-600 hover:underline">
                                            {r.code}
                                        </Link>
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2">{r.arrival_date ?? '—'}</td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {Number(r.quantity)} {r.unit}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {r.unit_price !== null ? (
                                            formatUnitCost(r.unit_price)
                                        ) : (
                                            <span className="text-amber-700">{t('purchasing.unpriced')}</span>
                                        )}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {appliedByBatch.has(r.id) ? formatMoney(appliedByBatch.get(r.id)) : '—'}
                                    </td>
                                    <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                        {r.unit_price !== null ? formatMoney(openByBatch.get(r.id) ?? 0) : '—'}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </>
            ) : (
                <p className="text-sm text-gray-500">{t('purchasing.noReceipts')}</p>
            )}
        </div>
    )
}
