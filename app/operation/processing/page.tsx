// app/operation/processing/page.tsx
// 加工单列表页(只读,删除在详情页)。日期区间(process_date)+ 分页,端口自 inbound。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ Q7:sort/dir 仍然由 ProcessingToolbar 写 URL、由服务端执行,DataTable 不接管
//   排序。转换前后的行序用 fetch 对拍验过(不是断言)。
// ★ state 恒为 'ok' —— 筛选/排序工具栏是真实出口,见 §⑩-3。
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { processingStatusLabelKey } from '../status'
import ProcessingToolbar from './ProcessingToolbar'
import {
    parseProcessingListParams,
    parseProcessingPage,
    applyProcessingFilters,
    PROCESSING_PAGE_SIZE,
} from '../processingQuery'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import ProcessingTable, { type ProcessingRunRow } from './ProcessingTable'

export default async function ProcessingPage({
    searchParams,
}: {
    searchParams: Promise<{
        date_from?: string
        date_to?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // 状态标签(未知值回退原样)
    const statusLabel = (v: string | null) => {
        const k = processingStatusLabelKey(v)
        return k ? t(k) : v ?? '—'
    }

    const { dateFrom, dateTo, sort, dir } = parseProcessingListParams(sp)
    const requestedPage = parseProcessingPage(sp.page)
    const filterParams = { dateFrom, dateTo, sort, dir }

    // 1) 匹配总数
    const { count } = await applyProcessingFilters(
        supabase.from('processing_runs').select('id', { count: 'exact', head: true }),
        filterParams
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PROCESSING_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PROCESSING_PAGE_SIZE
    const to = from + PROCESSING_PAGE_SIZE - 1

    // 2) 取当前页
    const baseQuery = supabase
        .from('processing_runs')
        .select('id, code, process_date, total_input, total_output, loss_qty, status, created_at, work_order_id')

    const { data: runs, error } = await applyProcessingFilters(baseQuery, filterParams).range(from, to)

    // WO-1c:把这一页上出现的工单编号一次取回来 —— 逐行去查会是 N+1,
    // 而列表最多 PROCESSING_PAGE_SIZE 行,一次 in() 就够。
    const woIds = Array.from(new Set((runs ?? [])
        .map((r) => (r as { work_order_id: string | null }).work_order_id)
        .filter(Boolean))) as string[]
    const woCode = new Map<string, string>()
    if (woIds.length > 0) {
        const woRows = mustRows(
            await supabase.from('work_orders').select('id, code').in('id', woIds),
            'work_orders') as { id: string; code: string }[]
        woRows.forEach((w) => woCode.set(w.id, w.code))
    }

    // 分页链接:保留日期 + sort/dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/operation/processing?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('processing.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const tableRows: ProcessingRunRow[] = (runs ?? []).map((r) => ({
        id: r.id,
        code: r.code,
        processDate: r.process_date ?? '—',
        totalInput: r.total_input != null ? String(r.total_input) : '—',
        totalOutput: r.total_output != null ? String(r.total_output) : '—',
        lossLabel:
            (r.loss_qty != null ? String(r.loss_qty) : '—') +
            (r.loss_qty != null && r.total_input ? ` (${((r.loss_qty / r.total_input) * 100).toFixed(1)}%)` : ''),
        statusLabel: statusLabel(r.status),
        workOrderId: r.work_order_id,
        workOrderCode: r.work_order_id ? (woCode.get(r.work_order_id) ?? '—') : '—',
    }))

    return (
        <ListPage
            title={t('processing.listTitle')}
            actions={
                <Link
                    href="/operation/processing/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('processing.addButton')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <ProcessingToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('processing.recordCount', { count: total })}
            </p>

            <ProcessingTable rows={tableRows} empty={t('processing.emptyState')} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('processing.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('processing.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('processing.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('processing.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('processing.pagination.next')}
                    </span>
                )}
            </div>
        </ListPage>
    )
}
