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
import { formatAmount, formatMoneyBare, formatTimestamp } from '@/lib/format'
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

export default async function PayableDocPage({
    params,
}: {
    params: Promise<{ batchId: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

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


    // ★【行数据在服务端压平】金额格式要 baseCurrency,只有服务端知道(CONV-1 §①)。
    const tableRows: SettlementRow[] = allocs.map((a) => ({
        id: a.id,
        paymentCode: a.payments?.code ?? '—',
        paymentHref: a.payments ? `/finance/payments/${a.payments.id}` : null,
        paymentDate: a.payments?.payment_date ?? '—',
        allocatedText: formatAmount(a.allocated_base, baseCurrency),
        reversed: a.payments?.status === 'reversed',
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    //   代价照直写:转换前这个标签 colSpan={2} 横跨【付款单+日期】两列,
    //   现在落在【付款单】那一列里。列进人工走查清单。
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
                <Link href="/finance/payables" className="text-blue-600 hover:underline text-sm">
                    {t('finance.backToAging')}
                </Link>
            }
            title={t('finance.apDocTitle')}
            // ★★ 详情页恒为 ok —— 这张单在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一块 bg-gray-50 的面板(四种写法之一)。
                这一页没有记录级动作,所以 actions 槽不给 —— 不给就不画。 */}
            <RecordHeader
                fields={[
                    {
                        label: t('finance.colDocument'),
                        value: (
                            <>
                                <Link
                                    href={`/inbound/${batch.id}/edit`}
                                    className="text-blue-600 hover:underline font-mono font-medium"
                                >
                                    {batch.code}
                                </Link>
                                <span className="text-gray-500 ml-2">{materialName}</span>
                            </>
                        ),
                    },
                    { label: t('finance.colCounterparty'), value: supplierRes.data?.legal_name ?? '—' },
                    { label: t('finance.colDate'), value: docDate },
                    {
                        label: t('finance.amount'),
                        value:
                            amountBase !== null ? (
                                <>
                                    <span className="font-mono">
                                        {batch.quantity} × {batch.unit_price}
                                    </span>
                                    <span className="font-mono font-medium ml-1">
                                        = {formatMoneyBare(amountBase, '同格内紧随其后的 {baseCurrency} 后缀')} {baseCurrency}
                                    </span>
                                </>
                            ) : (
                                <span className="font-mono">—</span>
                            ),
                    },
                    { label: t('finance.settledAmount'), value: formatAmount(settled, baseCurrency), mono: true },
                    {
                        label: t('finance.openAmount'),
                        value: (
                            <span className="font-bold">
                                {open !== null ? formatAmount(open, baseCurrency) : '—'}
                            </span>
                        ),
                        mono: true,
                    },
                ]}
            />

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
            <SettlementHistoryTable rows={tableRows} />

            {/* 凭据附件 —— 这一页唯一的出口(上传凭据)。它住在 children 里,
                而详情页 state 恒为 'ok',所以它不可能被空分支吃掉。 */}
            <FinanceAttachmentsPanel parent={{ kind: 'inbound', id: batch.id }} rows={attachments} />
        </ListPage>
    )
}
