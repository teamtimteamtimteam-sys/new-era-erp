// app/finance/invoices/page.tsx
// 发票列表:最新在前(issue_date DESC),issue_date 区间 + 收款状态 + 单据状态筛选,
// count+range 分页(端口自收付款列表)。
// 已开具的发票读 invoice_status(带已收/未收/逾期);【作废的不在那张视图里】,
// 需要时另查 invoices 本表并标注为已作废(其结算数字无意义,留空)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { fetchAllPages } from '@/lib/export/serverRows'
import {
    parseInvoiceListParams, issuedCount, issuedPage, voidCount, voidPage, shapeInvoiceRows, invoiceExportHref,
    type InvoiceDbRow,
} from './invoiceRows'
import InvoicesToolbar from './InvoicesToolbar'
import InvoicesTable, { type InvoiceRow } from './InvoicesTable'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function InvoicesPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; state?: string; status?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // TABLE-EXPORT-2a:读取与「库里的行 → 表的行」搬进 invoiceRows.ts,与导出路由共用一份。
    const params = parseInvoiceListParams(sp)
    const { dateFrom, dateTo, state, status } = params
    const requestedPage = parsePage(sp.page)

    let rows: InvoiceDbRow[] = []
    let total = 0
    let page = 1
    let totalPages = 1

    if (status === 'void') {
        // 只看作废:invoice_status 里没有它们,直接查本表
        total = mustCount(await voidCount(supabase, params), 'invoices void count')
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        rows = mustRows(await voidPage(supabase, params, (page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1), 'invoices void')
    } else {
        total = mustCount(await issuedCount(supabase, params), 'invoice_status count')
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        rows = mustRows(await issuedPage(supabase, params, (page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1), 'invoice_status')

        // status='all' 时把作废的补在后面(它们没有结算数字)
        if (status === 'all') {
            const voidRows = await fetchAllPages((from, to) => voidPage(supabase, params, from, to), 'invoices void (all)')
            rows = [...rows, ...voidRows]
            total += voidRows.length
        }
    }

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (state) params.set('state', state)
        if (sp.status) params.set('status', sp.status)
        params.set('page', String(targetPage))
        return `/finance/invoices?${params.toString()}`
    }

    const tableRows: InvoiceRow[] = await shapeInvoiceRows(rows)

    return (
        <ListPage
            title={t('invoice.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/finance/invoices/new">{t('invoice.new')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <InvoicesToolbar />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.recordCount', { count: total })}</p>

            <InvoicesTable rows={tableRows} empty={t('invoice.empty')} exportHref={invoiceExportHref(params)} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link href={pageHref(page - 1)}>
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
                        <Link href={pageHref(page + 1)}>
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
