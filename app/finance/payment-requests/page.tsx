// app/finance/payment-requests/page.tsx
// PAY-REQ-1(Tim 2026-09-23):付款申请列表。钱离开之前要先批 —— 出款与冲销先成一张
// 申请(提 → CFO 批 → 财务付),这一页是它们的登记簿。
//
// 【默认只看未了结的】submitted(等 CFO 批)与 approved(等财务付)—— 那是这一页要人
// 动手的两种;其余状态经筛选链接看得见,不藏。count + range 分页,不静默截断。
// 收款人名按页小批量反查(供应商 / 员工 / 客户三次 .in,走查名视图)。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import PaymentRequestsTable, { type PaymentRequestRow } from './PaymentRequestsTable'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { REQUEST_STATUSES, parseRequestFilter, parseRequestSort, requestCount, requestPage, shapeRequestRows, requestExportHref, requestTotals } from './requestRows'
import { ListPage } from '@/app/components/ui/list-page'
import { setSortParams } from '@/lib/listSort'
import { Suspense } from 'react'
import { SavedViewsBar } from '@/app/components/ui/saved-views'
import { loadSavedViews } from '@/lib/savedViewsServer'
import { filteredListHref } from '@/lib/savedViews'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function PaymentRequestsPage({
    searchParams,
}: {
    searchParams: Promise<{ status?: string; page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // TABLE-FEATURES-3(Tim 2026-10-26 Q1–Q3):保存的视图 —— 地址为空时套用本人的默认视图(一次跳转,所以在任何别的查询之前)
    const savedViews = await loadSavedViews(supabase, { listKey: '/finance/payment-requests', sp })
    const t = await getTranslations()

    // TABLE-EXPORT-2a:读取与映射搬进 requestRows.ts,与导出路由共用一份。
    const filter = parseRequestFilter(sp.status)
    const sort = parseRequestSort(sp)  // TABLE-FEATURES-1 Q9
    const requestedPage = parsePage(sp.page)

    const total = mustCount(await requestCount(supabase, filter), 'payment requests count')
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE

    const rows = mustRows(await requestPage(supabase, filter, sort, from, from + PAGE_SIZE - 1), 'payment requests')
    const tableRows: PaymentRequestRow[] = await shapeRequestRows(supabase, rows)
    const totals = await requestTotals(supabase, filter)  // TABLE-FEATURES-2 Q1:所有符合筛选的行,不只这一页

    // TABLE-FEATURES-1 Q9:翻页链接保留排序(keepSort);换筛选的链接回到默认次序
    const href = (status: string, p = 1, keepSort = false) => {
        const params = new URLSearchParams()
        if (status !== 'open') params.set('status', status)
        if (keepSort) setSortParams(params, sort)
        if (p > 1) params.set('page', String(p))
        return filteredListHref('/finance/payment-requests', params) // SYSTEM-MAP-1 D1
    }
    const filters = ['open', ...REQUEST_STATUSES, 'all']

    return (
        <ListPage
            title={t('finance.paymentRequests.title')}
            intro={t('finance.paymentRequests.intro')}
            actions={
                <Button asChild>
                    <Link href="/finance/payments/new?direction=out">{t('finance.paymentRequests.newRequest')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={null}><SavedViewsBar listKey="/finance/payment-requests" views={savedViews} /></Suspense>
            <nav className="flex flex-wrap gap-2 mb-4" aria-label={t('finance.paymentRequests.filterLabel')}>
                {filters.map((f) => (
                    <Button key={f} asChild size="sm" variant={f === filter ? 'default' : 'outline'}>
                        <Link href={href(f)} aria-current={f === filter ? 'page' : undefined}>
                            {f === 'open' ? t('finance.paymentRequests.filterOpen')
                                : f === 'all' ? t('finance.paymentRequests.filterAll')
                                : t('finance.paymentRequests.status.' + f)}
                        </Link>
                    </Button>
                ))}
            </nav>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {t('finance.recordCount', { count: total })}
            </p>

            <PaymentRequestsTable rows={tableRows} empty={t('finance.paymentRequests.empty')} exportHref={requestExportHref(filter, sort)}
                                  sort={sort} shown={tableRows.length} total={total} totals={totals} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link href={href(filter, page - 1, true)}>{t('finance.pagination.prev')}</Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>{t('finance.pagination.prev')}</Button>
                )}
                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link href={href(filter, page + 1, true)}>{t('finance.pagination.next')}</Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>{t('finance.pagination.next')}</Button>
                )}
            </div>
        </ListPage>
    )
}
