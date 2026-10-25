// app/finance/payments/page.tsx
// 收付款列表:最新在前,payment_date 日期区间 + 方向筛选 + count+range 分页
// (端口自分录列表)。往来单位名按页小批量反查(客户/供应商两次 .in)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import PaymentsToolbar from './PaymentsToolbar'
import PaymentsTable, { type PaymentRow } from './PaymentsTable'
import { mustCount } from '@/lib/db-helpers'
import { parsePaymentListParams, paymentCount, paymentPage, shapePaymentRows, paymentExportHref } from './paymentRows'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { setSortParams } from '@/lib/listSort'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function PaymentsListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; direction?: string; page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // TABLE-EXPORT-2a:读取与「库里的行 → 表的行」搬进 paymentRows.ts,与导出路由共用一份。
    const params = parsePaymentListParams(sp)
    const listParams = params
    const { dateFrom, dateTo, direction } = params
    const requestedPage = parsePage(sp.page)

    // 1) 匹配总数 —— 数不出来就失败(mustCount),不读成 0
    const total = mustCount(await paymentCount(supabase, params), 'payments count')
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    // 2) 取当前页(创建序最新在前)
    const { data: payments, error } = await paymentPage(supabase, params, from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="mb-4">{t('finance.paymentsTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (direction) params.set('direction', direction)
        setSortParams(params, listParams.sort)
        params.set('page', String(targetPage))
        return `/finance/payments?${params.toString()}`
    }

    // 3) 往来单位名(按 id 反查)与映射 —— 在 paymentRows.ts 里,与导出同一份
    const tableRows: PaymentRow[] = await shapePaymentRows(supabase, payments ?? [])

    return (
        <ListPage
            title={t('finance.paymentsTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/payments/new">{t('finance.recordPayment')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <PaymentsToolbar />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {t('finance.recordCount', { count: total })}
            </p>

            <PaymentsTable rows={tableRows} empty={t('finance.paymentsEmpty')} exportHref={paymentExportHref(params)}
                           sort={params.sort} shown={tableRows.length} total={total} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
