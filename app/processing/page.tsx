// app/processing/page.tsx
// 加工单列表页(只读,删除在详情页)。日期区间(process_date)+ 分页,端口自 inbound。
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import { processingStatusLabelKey } from './status'
import ProcessingToolbar from './ProcessingToolbar'
import {
    parseProcessingListParams,
    parseProcessingPage,
    applyProcessingFilters,
    PROCESSING_PAGE_SIZE,
} from './processingQuery'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { getFunctionAccess } from '@/lib/moduleAccess'
import Subnav from './Subnav'

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
        return `/processing?${params.toString()}`
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

    return (
        <>
        <Subnav />
        <div className="p-8">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('processing.listTitle')}</h1>
                <div className="flex items-center gap-3">
                    {/* 【加工模块名下的跨模块功能】NAV-REG-1:这里从前是一个手写的
                        <Link href="/margin">,与权限之间没有任何东西保证同步。
                        现在整条来自注册表 —— 地址、标签、以及"这个人进不进得去"
                        都是 FN.margin 那一条,而 /margin 自己的守卫读的是同一条。
                        加工这侧没有子导航,所以入口仍然放在页头(位置一字未动)。 */}
                    {(await getFunctionAccess('/processing')).map(({ fn, allowed }) =>
                        allowed ? (
                            <Link key={fn.href} href={fn.href} className="text-sm text-blue-600 hover:underline">
                                {t(fn.navKey)}
                            </Link>
                        ) : (
                            <span
                                key={fn.href}
                                data-module-restricted="1"
                                title={t('dashboard.restrictedHint')}
                                className="text-sm text-gray-400 cursor-default"
                            >
                                {t(fn.navKey)} · {t('common.restricted')}
                            </span>
                        ),
                    )}
                    <Link
                        href="/processing/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('processing.addButton')}
                    </Link>
                </div>
            </div>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <ProcessingToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('processing.recordCount', { count: total })}
            </p>

            <div className="overflow-x-auto">
                <table className="w-full border-collapse border border-gray-300">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colCode')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colProcessDate')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colTotalInput')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colTotalOutput')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colLoss')}</th>
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colStatus')}</th>
                            {/* WO-1c:这次加工算在哪张计划上 —— 【没有就说"无计划",不留空】
                                空白读起来是"数据缺了",而真相是一个正当的类别。 */}
                            <th className="border border-gray-300 px-4 py-2 text-left">{t('processing.colWorkOrder')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {runs?.map((r) => (
                            <tr key={r.id}>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    <Link
                                        href={`/processing/${r.id}`}
                                        className="text-blue-600 hover:underline"
                                    >
                                        {r.code}
                                    </Link>
                                </td>
                                <td className="border border-gray-300 px-4 py-2">{r.process_date ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.total_input ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">{r.total_output ?? '—'}</td>
                                <td className="border border-gray-300 px-4 py-2">
                                    {r.loss_qty ?? '—'}
                                    {r.loss_qty != null && r.total_input
                                        ? ` (${((r.loss_qty / r.total_input) * 100).toFixed(1)}%)`
                                        : ''}
                                </td>
                                <td className="border border-gray-300 px-4 py-2">
                                    <span className="px-2 py-1 bg-gray-200 rounded text-xs">
                                        {statusLabel(r.status)}
                                    </span>
                                </td>
                                <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                    {r.work_order_id
                                        ? <Link href={`/processing/orders/${r.work_order_id}`}
                                                className="text-blue-600 hover:underline">
                                              {woCode.get(r.work_order_id) ?? '—'}
                                          </Link>
                                        : <span className="text-gray-500 italic">{t('processing.noWorkOrder')}</span>}
                                </td>
                            </tr>
                        ))}
                        {(!runs || runs.length === 0) && (
                            <tr>
                                <td
                                    colSpan={7}
                                    className="border border-gray-300 px-4 py-8 text-center text-gray-500"
                                >
                                    {t('processing.emptyState')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                </table>
            </div>

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
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
        </div>
        </>
    )
}
