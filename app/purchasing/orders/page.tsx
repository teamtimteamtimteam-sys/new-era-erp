// app/purchasing/orders/page.tsx
// 采购单列表:最新在前(order_date DESC),order_date 区间 + 供应商 + 状态筛选,
// count+range 分页(端口自发票列表)。
// 在册且未取消的走 purchase_order_status(带已预付/收货进度);【已取消的不在视图里】,
// 筛选状态为 cancelled 时另查 purchase_orders 本表(其预付/进度数字无意义,留空)。
// OPS-14:预付两列在没有 module.finance.view 时【也是 null】—— 于是 null 有两个含义,
// 「已取消所以无意义」与「你看不见」。前者画「—」,后者画「受限」,靠权限码分开。
// CCY-1:这张表里【并排两种币】——「估算总额」是采购单自己的币种(po.currency),
// 「已预付」与那个未抵扣角标是本位币(*_base)。列头一个币种也没写,两列挨着,
// 于是 12,000 与 8,100 看着像同一种钱。两列各自带上币种,不省。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatAmount } from '@/lib/format'
import { getBaseCurrency } from '@/lib/currency'
import { can } from '@/lib/permissions'
import { MaskedValue } from '@/app/components/MaskedValue'
import OrdersToolbar from './OrdersToolbar'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

type Row = {
    po_id: string
    code: string
    supplier_name: string | null
    order_date: string
    expected_delivery_date: string | null
    currency: string
    estimated_total_ccy: number
    prepaid_base: number | null
    prepaid_remaining_base: number | null
    receipt_pct: number | null
    status: string
}

const STATUSES = ['draft', 'confirmed', 'receiving', 'closed', 'cancelled']

export default async function PurchaseOrdersPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; supplier?: string; status?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const canFinance = await can('module.finance.view')
    // 预付列是本位币 —— 从 currencies.is_base 取,不写死
    const baseCurrency = await getBaseCurrency()

    const { dateFrom, dateTo } = parseDateRange(sp)
    const supplier = (sp.supplier ?? '').trim()
    const status = STATUSES.includes(sp.status ?? '') ? sp.status! : ''
    const requestedPage = parsePage(sp.page)

    interface Chain {
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        eq(c: string, v: string): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dateFrom) chain = chain.gte('order_date', dateFrom)
        if (dateTo) chain = chain.lte('order_date', dateTo)
        if (supplier) chain = chain.eq('supplier_id', supplier)
        return chain as unknown as T
    }

    let rows: Row[] = []
    let total = 0
    let page = 1
    let totalPages = 1

    if (status === 'cancelled') {
        // 只看已取消:视图里没有它们,直接查本表
        const { count } = await applyFilters(
            supabase.from('purchase_orders').select('id', { count: 'exact', head: true }).eq('status', 'cancelled').is('deleted_at', null)
        )
        total = count ?? 0
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        const { data } = await applyFilters(
            supabase
                .from('purchase_orders_masked')
                .select('id, code, order_date, expected_delivery_date, currency, estimated_total_ccy, status, suppliers(legal_name)')
                .eq('status', 'cancelled')
                .is('deleted_at', null)
        )
            .order('order_date', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1)
        rows = ((data as unknown as { id: string; code: string; order_date: string; expected_delivery_date: string | null; currency: string; estimated_total_ccy: number; status: string; suppliers: { legal_name: string } | null }[] | null) ?? []).map((r) => ({
            po_id: r.id,
            code: r.code,
            supplier_name: r.suppliers?.legal_name ?? null,
            order_date: r.order_date,
            expected_delivery_date: r.expected_delivery_date,
            currency: r.currency,
            estimated_total_ccy: r.estimated_total_ccy,
            prepaid_base: null,
            prepaid_remaining_base: null,
            receipt_pct: null,
            status: r.status,
        }))
    } else {
        const applyStatus = <T,>(query: T): T => {
            let chain = applyFilters(query) as unknown as Chain
            if (status) chain = chain.eq('status', status)
            return chain as unknown as T
        }
        const { count } = await applyStatus(
            supabase.from('purchase_order_status').select('po_id', { count: 'exact', head: true })
        )
        total = count ?? 0
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        const { data } = await applyStatus(
            supabase
                .from('purchase_order_status')
                .select('po_id, code, supplier_name, order_date, expected_delivery_date, currency, estimated_total_ccy, prepaid_base, prepaid_remaining_base, receipt_pct, status')
        )
            .order('order_date', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1)
        rows = ((data as unknown as Row[] | null) ?? [])
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (supplier) params.set('supplier', supplier)
        if (status) params.set('status', status)
        params.set('page', String(targetPage))
        return `/purchasing/orders?${params.toString()}`
    }

    // 工具栏的供应商选项
    const { data: supplierRows } = await supabase
        .from('suppliers')
        .select('id, legal_name')
        .is('deleted_at', null)
        // LOG-1b:货代不进供应商名单
        .neq('counterparty_type', 'forwarder')
        .order('legal_name')
    const supplierOptions = (supplierRows ?? []).map((s) => ({ id: s.id, name: s.legal_name }))

    const statusPill = (s: string) => {
        const cls =
            s === 'confirmed' || s === 'receiving'
                ? 'bg-green-100 text-green-800'
                : s === 'closed'
                  ? 'bg-gray-200 text-gray-700'
                  : s === 'cancelled'
                    ? 'bg-red-100 text-red-700'
                    : 'bg-amber-100 text-amber-800'
        return <span className={'px-2 py-1 rounded text-xs ' + cls}>{t('purchasing.status.' + s)}</span>
    }

    return (
        <div className="p-8">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('purchasing.ordersTitle')}</h1>
                <Link
                    href="/purchasing/orders/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('purchasing.newOrder')}
                </Link>
            </div>

            <Suspense fallback={<div className="mb-4 h-10" />}>
                <OrdersToolbar suppliers={supplierOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colCode')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colSupplier')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colOrderDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colExpectedDelivery')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colEstimatedTotal')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('purchasing.colPrepaid')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colReceipt')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('purchasing.colStatus')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.po_id} className={r.status === 'cancelled' ? 'text-gray-400' : ''}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link
                                    href={`/purchasing/orders/${r.po_id}`}
                                    className={
                                        r.status === 'cancelled'
                                            ? 'text-gray-500 hover:underline line-through'
                                            : 'text-blue-600 hover:underline'
                                    }
                                >
                                    {r.code}
                                </Link>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{r.supplier_name ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.order_date}</td>
                            <td className="border border-gray-300 px-4 py-2">{r.expected_delivery_date ?? '—'}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatAmount(r.estimated_total_ccy, r.currency)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                <MaskedValue value={r.prepaid_base === null ? null : formatAmount(r.prepaid_base, baseCurrency)} canView={canFinance} fallback="—" />
                                {/* 搁浅的定金要不点开每张单也看得见(cut 4c)*/}
                                {canFinance && (r.prepaid_remaining_base ?? 0) > 0 && (
                                    <span
                                        title={t('purchasing.unappliedMarker')}
                                        className="ml-2 inline-block px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 font-sans"
                                    >
                                        ⚠ {formatAmount(r.prepaid_remaining_base ?? 0, baseCurrency)}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {r.receipt_pct === null ? (
                                    '—'
                                ) : (
                                    <div className="flex items-center gap-2">
                                        {/* 收货进度条:>100%(超收)封顶显示 */}
                                        {/* CHART-1 ④:配色换成品牌 token。**这不是新建一张图** ——
                                            它是屏幕上原本就在用图形承载数字的两处之一,而它用的
                                            bg-gray-200 / bg-green-500 正是 R5 点名不要的那种默认色阶。
                                            不换的话,新图与旧图会是两套配色。判词见 docs/charts-scoping.md §A1:
                                            **留着,只换配色** —— 它是"一行里的一个数",放大成图表反而更差。 */}
                                        <div className="w-20 h-2 rounded overflow-hidden"
                                             style={{ background: 'var(--brand-muted)' }}>
                                            <div
                                                className="h-full"
                                                style={{ width: `${Math.min(100, r.receipt_pct)}%`,
                                                         background: 'var(--brand-forest-fill)' }}
                                            />
                                        </div>
                                        <span className="text-xs text-gray-600 font-mono">{r.receipt_pct}%</span>
                                    </div>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{statusPill(r.status)}</td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('purchasing.empty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link href={pageHref(page - 1)} className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50">
                        {t('finance.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.prev')}
                    </span>
                )}
                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Link href={pageHref(page + 1)} className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50">
                        {t('finance.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('finance.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
