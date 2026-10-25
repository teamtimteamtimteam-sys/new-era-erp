// app/operation/processing/page.tsx
// 加工单列表页(只读,删除在详情页)。日期区间(process_date)+ 分页,端口自 inbound。
//
// CONV-5:套 CONV-1 的两文件模板。
// ★ Q7:sort/dir 仍然由 ProcessingToolbar 写 URL、由服务端执行,DataTable 不接管
//   排序。转换前后的行序用 fetch 对拍验过(不是断言)。
// ★ TABLE-FEATURES-1(Tim 2026-10-25 Q9 · Q7):上面那条被取代 —— ProcessingToolbar 从来没写过 sort/dir,
//   这一页有参数没有控件。现在表头是链接(DataTable 的 server 模式),仍由服务端执行;默认改为加工日新的在前。
// ★ state 恒为 'ok' —— 筛选/排序工具栏是真实出口,见 §⑩-3。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import { getTranslations } from '@/lib/i18n/server'
import ProcessingToolbar from './ProcessingToolbar'
import {
    parseProcessingListParams,
    parseProcessingPage,
    PROCESSING_PAGE_SIZE,
} from '../processingQuery'
import { processingCount, processingPage, shapeProcessingRows } from './processingRows'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ListPage } from '@/app/components/ui/list-page'
import ProcessingTable, { type ProcessingRunRow } from './ProcessingTable'
import { setSortParams } from '@/lib/listSort'

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

    const filterParams = parseProcessingListParams(sp)
    const { dateFrom, dateTo, sort } = filterParams
    const requestedPage = parseProcessingPage(sp.page)

    // 1) 匹配总数(TABLE-EXPORT-1:读取挪进 processingRows.ts,与导出路由共用一份)
    const { count } = await processingCount(supabase, filterParams)

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PROCESSING_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PROCESSING_PAGE_SIZE
    const to = from + PROCESSING_PAGE_SIZE - 1

    // 2) 取当前页 —— 工单编号与物料平衡状态的补读也在 shapeProcessingRows 里(WO-1c · MES-4a)
    const { data: runs, error } = await processingPage(supabase, filterParams, from, to)

    // 分页链接:保留日期 + sort/dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        setSortParams(params, sort)
        params.set('page', String(targetPage))
        return `/operation/processing?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('processing.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('processing.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    const tableRows: ProcessingRunRow[] = await shapeProcessingRows(supabase, runs ?? [])
    // TABLE-EXPORT-1 Q2:导出取【全部匹配行】—— 同一套筛选与排序,不带 page。
    const exportParams = new URLSearchParams()
    if (dateFrom) exportParams.set('date_from', dateFrom)
    if (dateTo) exportParams.set('date_to', dateTo)
    setSortParams(exportParams, sort)
    const exportHref = `/operation/processing/export?${exportParams.toString()}`

    const canCommit = await can('action.processing_commit')

    return (
        <ListPage
            title={t('processing.listTitle')}
            actions={
                // ROLE-1 Batch 3b:建加工单 = commit_processing_run,归 action.processing_commit。
                // 缺码时画真的 <Button disabled>(链接禁不掉),由 PermissionGate 点名那个码。
                canCommit ? (
                    <Button asChild>
                        <Link href="/operation/processing/new">{t('processing.addButton')}</Link>
                    </Button>
                ) : (
                    <PermissionGate code="action.processing_commit" allowed={false} inline>
                        <Button disabled>{t('processing.addButton')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <ProcessingToolbar />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {t('processing.recordCount', { count: total })}
            </p>

            <ProcessingTable rows={tableRows} empty={t('processing.emptyState')} exportHref={exportHref}
                             sort={sort} shown={tableRows.length} total={total} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('processing.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('processing.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('processing.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('processing.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('processing.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
