// app/purchasing/orders/page.tsx
// 采购单列表:最新在前(order_date DESC),order_date 区间 + 供应商 + 状态筛选,
// count+range 分页(端口自发票列表)。
// 在册且未取消的走 purchase_order_status(带已预付/收货进度);【已取消的不在视图里】,
// 筛选状态为 cancelled 时另查 purchase_orders 本表(其预付/进度数字无意义,留空)。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { formatMoney } from '@/lib/format'
import Subnav from '../Subnav'
import OrdersToolbar from './OrdersToolbar'

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
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

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
                .select('id, code, order_date, expected_delivery_date, estimated_total_ccy, status, suppliers(legal_name)')
                .eq('status', 'cancelled')
                .is('deleted_at', null)
        )
            .order('order_date', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1)
        rows = ((data as unknown as { id: string; code: string; order_date: string; expected_delivery_date: string | null; estimated_total_ccy: number; status: string; suppliers: { legal_name: string } | null }[] | null) ?? []).map((r) => ({
            po_id: r.id,
            code: r.code,
            supplier_name: r.suppliers?.legal_name ?? null,
            order_date: r.order_date,
            expected_delivery_date: r.expected_delivery_date,
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
                .select('po_id, code, supplier_name, order_date, expected_delivery_date, estimated_total_ccy, prepaid_base, prepaid_remaining_base, receipt_pct, status')
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

            <Subnav />

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
                                {formatMoney(r.estimated_total_ccy)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {r.prepaid_base === null ? '—' : formatMoney(r.prepaid_base)}
                                {/* 搁浅的定金要不点开每张单也看得见(cut 4c)*/}
                                {(r.prepaid_remaining_base ?? 0) > 0 && (
                                    <span
                                        title={t('purchasing.unappliedMarker')}
                                        className="ml-2 inline-block px-1.5 py-0.5 rounded text-xs bg-amber-100 text-amber-800 font-sans"
                                    >
                                        ⚠ {formatMoney(r.prepaid_remaining_base ?? 0)}
                                    </span>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {r.receipt_pct === null ? (
                                    '—'
                                ) : (
                                    <div className="flex items-center gap-2">
                                        {/* 收货进度条:>100%(超收)封顶显示 */}
                                        <div className="w-20 h-2 bg-gray-200 rounded overflow-hidden">
                                            <div
                                                className="h-full bg-green-500"
                                                style={{ width: `${Math.min(100, r.receipt_pct)}%` }}
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
