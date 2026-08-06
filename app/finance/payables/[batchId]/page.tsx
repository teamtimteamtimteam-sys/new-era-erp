// app/finance/payables/[batchId]/page.tsx
// AP 单据详情:头部卡(单据号 = 进料批次编号,链批次编辑页;供应商/到货日/
// 数量×单价 = 单据额/已结/未结)+ 结算历史(同 AR 页:reversed 付款的核销不计入
// 已结额,但以灰色删除线行保留)+ 凭据附件面板 + 关联采购分录
// (source_type='purchase', source_id=批次 id —— 改价后可能有多条,全部列出)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getBaseCurrency } from '@/lib/currency'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { formatMoney, formatTimestamp } from '@/lib/format'
import Subnav from '../../Subnav'
import FinanceAttachmentsPanel from '@/app/components/finance/FinanceAttachmentsPanel'
import { unmasked } from '@/lib/maskedRows'
import type { Tables } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

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

export default async function PayableDocPage({
    params,
}: {
    params: Promise<{ batchId: string }>
}) {
    const { batchId } = await params
    const supabase = await createClient()
    const t = await getTranslations()
    const baseCurrency = await getBaseCurrency()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { data: batchRaw, error } = await supabase
        .from('inbound_batches_masked')
        .select('id, code, supplier_id, quantity, unit, unit_price, arrival_date, notes, created_at, materials(name)')
        .eq('id', batchId)
        .single()

    if (error || !batchRaw) {
        notFound()
    }

    // cut 2b:改读遮蔽视图(基表的原始敏感列已被收回)。这里断言回基表行类型 ——
    // 能进到这个页面的角色(admin / finance / auditor)全都持有 data.view_prices,
    // 所以这些列不会被遮蔽。理由与失效条件见 lib/maskedRows.ts。
    const batch = unmasked<Tables<'inbound_batches'> & { materials: { name: string } | null }>(batchRaw)

    // 应付额 = 当前 quantity × unit_price(与 ap_open_items 口径一致;未计价 → 0 敞口页不会链进来,
    // 但直接访问 URL 也要能看:金额区显示 —)
    const amountBase =
        batch.unit_price !== null ? Math.round(batch.quantity * batch.unit_price * 100) / 100 : null
    const docDate = batch.arrival_date ?? batch.created_at?.slice(0, 10) ?? '—'

    // 供应商 / 结算历史 / 采购分录(改价后可能多条)/ 附件,页级小查询
    const [supplierRes, allocsRes, journalsRes, attachRes] = await Promise.all([
        batch.supplier_id
            ? supabase.from('suppliers').select('legal_name').eq('id', batch.supplier_id).single()
            : Promise.resolve({ data: null, error: null }),
        supabase
            .from('payment_allocations')
            .select('id, allocated_base, payments(id, code, payment_date, status)')
            .eq('inbound_batch_id', batchId)
            .order('created_at', { ascending: true }),
        supabase
            .from('journal_entries')
            .select('id, code')
            .eq('source_type', 'purchase')
            .eq('source_id', batchId)
            .order('created_at', { ascending: true }),
        supabase
            .from('finance_attachments')
            .select('id, file_name, file_path, file_size, mime_type, doc_type, notes, created_at')
            .eq('inbound_batch_id', batchId)
            .is('deleted_at', null)
            .order('created_at', { ascending: false }),
    ])

    const allocs = ((allocsRes.data as unknown as AllocRow[] | null) ?? [])

    // 已结额只计 posted 付款的核销(与 ap_open_items 口径一致);reversed 行仍展示。
    const settled =
        Math.round(
            allocs
                .filter((a) => a.payments?.status === 'posted')
                .reduce((s, a) => s + a.allocated_base, 0) * 100
        ) / 100
    const open = amountBase !== null ? Math.round((amountBase - settled) * 100) / 100 : null

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

    const materialName = (batch.materials as unknown as { name: string } | null)?.name ?? '—'

    return (
        <div className="p-8 max-w-4xl">
            <div className="mb-6">
                <Link href="/finance/payables" className="text-blue-600 hover:underline text-sm">
                    {t('finance.backToAging')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-2">{t('finance.apDocTitle')}</h1>

            <Subnav />

            {/* 头部卡 */}
            <div className="bg-gray-50 rounded p-4 mb-6 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colDocument')}:</span>
                    <Link
                        href={`/inbound/${batch.id}/edit`}
                        className="text-blue-600 hover:underline font-mono font-medium"
                    >
                        {batch.code}
                    </Link>
                    <span className="text-gray-500 ml-2">{materialName}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colCounterparty')}:</span>
                    <span>{supplierRes.data?.legal_name ?? '—'}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.colDate')}:</span>
                    <span>{docDate}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.amount')}:</span>
                    {amountBase !== null ? (
                        <>
                            <span className="font-mono">
                                {batch.quantity} × {batch.unit_price}
                            </span>
                            <span className="font-mono font-medium ml-1">= {formatMoney(amountBase)} {baseCurrency}</span>
                        </>
                    ) : (
                        <span className="font-mono">—</span>
                    )}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.settledAmount')}:</span>
                    <span className="font-mono">{formatMoney(settled)}</span>
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('finance.openAmount')}:</span>
                    <span className="font-mono font-bold">{open !== null ? formatMoney(open) : '—'}</span>
                </div>
            </div>

            {batch.notes && (
                <p className="text-sm text-gray-600 mb-4">
                    <span className="text-gray-500 mr-1">{t('finance.memo')}:</span>
                    {batch.notes}
                </p>
            )}

            {/* 关联采购分录(改价后可能多条,全部列出)*/}
            {(mustRows(journalsRes)).length > 0 && (
                <p className="text-sm mb-4">
                    <span className="text-gray-600 mr-1">{t('finance.relatedJournals')}:</span>
                    {(mustRows(journalsRes)).map((j, i) => (
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
                                    {formatMoney(a.allocated_base)}
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
                                {formatMoney(settled)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2" />
                        </tr>
                    </tfoot>
                )}
            </table>

            {/* 凭据附件 */}
            <FinanceAttachmentsPanel parent={{ kind: 'inbound', id: batch.id }} rows={attachments} />
        </div>
    )
}
