// app/finance/invoices/page.tsx
// 发票列表:最新在前(issue_date DESC),issue_date 区间 + 收款状态 + 单据状态筛选,
// count+range 分页(端口自收付款列表)。
// 已开具的发票读 invoice_status(带已收/未收/逾期);【作废的不在那张视图里】,
// 需要时另查 invoices 本表并标注为已作废(其结算数字无意义,留空)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Suspense } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import { getBaseCurrency } from '@/lib/currency'
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

type Row = {
    invoice_id: string
    code: string
    kind: string | null
    customer_name: string | null
    issue_date: string
    due_date: string
    total_base: number
    settled_base: number | null
    open_base: number | null
    payment_state: string | null
    days_overdue: number | null
    overdue: boolean
    is_void: boolean
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
    // 合计/已收/未收三列的列头都不写币种(「合计」「已收」「未收」)—— 数字自己带(CCY-1)
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const { dateFrom, dateTo } = parseDateRange(sp)
    const state = ['unpaid', 'partial', 'paid', 'overdue'].includes(sp.state ?? '') ? sp.state! : ''
    const status = sp.status === 'void' || sp.status === 'all' ? sp.status : 'issued'
    const requestedPage = parsePage(sp.page)

    interface Chain {
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        eq(c: string, v: string | boolean): Chain
        gt(c: string, v: number): Chain
    }
    const applyDates = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dateFrom) chain = chain.gte('issue_date', dateFrom)
        if (dateTo) chain = chain.lte('issue_date', dateTo)
        return chain as unknown as T
    }

    let rows: Row[] = []
    let total = 0
    let page = 1
    let totalPages = 1

    if (status === 'void') {
        // 只看作废:invoice_status 里没有它们,直接查本表
        const { count } = await applyDates(
            supabase.from('invoices').select('id', { count: 'exact', head: true }).eq('status', 'void')
        )
        total = count ?? 0
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        const { data } = await applyDates(
            supabase
                .from('invoices_masked')
                .select('id, code, customer_id, issue_date, due_date, total_base, customers(legal_name)')
                .eq('status', 'void')
        )
            .order('issue_date', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1)
        rows = ((data as unknown as { id: string; code: string; kind: string | null; issue_date: string; due_date: string; total_base: number; customers: { legal_name: string } | null }[] | null) ?? []).map((i) => ({
            invoice_id: i.id,
            code: i.code,
            kind: i.kind,
            customer_name: i.customers?.legal_name ?? null,
            issue_date: i.issue_date,
            due_date: i.due_date,
            total_base: i.total_base,
            settled_base: null,
            open_base: null,
            payment_state: null,
            days_overdue: null,
            overdue: false,
            is_void: true,
        }))
    } else {
        const applyState = <T,>(query: T): T => {
            let chain = applyDates(query) as unknown as Chain
            if (state === 'overdue') chain = chain.eq('overdue', true)
            else if (state) chain = chain.eq('payment_state', state)
            return chain as unknown as T
        }

        const { count } = await applyState(
            supabase.from('invoice_status').select('invoice_id', { count: 'exact', head: true })
        )
        total = count ?? 0
        totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
        page = Math.min(requestedPage, totalPages)
        const { data } = await applyState(supabase.from('invoice_status').select('*'))
            .order('issue_date', { ascending: false })
            .range((page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1)
        rows = ((data as unknown as Omit<Row, 'is_void'>[] | null) ?? []).map((r) => ({ ...r, is_void: false }))

        // status='all' 时把作废的补在后面(它们没有结算数字)
        if (status === 'all') {
            const { data: voids } = await applyDates(
                supabase
                    .from('invoices_masked')
                    .select('id, code, kind, issue_date, due_date, total_base, customers(legal_name)')
                    .eq('status', 'void')
            ).order('issue_date', { ascending: false })
            const voidRows = ((voids as unknown as { id: string; code: string; kind: string | null; issue_date: string; due_date: string; total_base: number; customers: { legal_name: string } | null }[] | null) ?? []).map((i) => ({
                invoice_id: i.id,
                code: i.code,
                kind: i.kind,
                customer_name: i.customers?.legal_name ?? null,
                issue_date: i.issue_date,
                due_date: i.due_date,
                total_base: i.total_base,
                settled_base: null,
                open_base: null,
                payment_state: null,
                days_overdue: null,
                overdue: false,
                is_void: true,
            }))
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

    const tableRows: InvoiceRow[] = rows.map((r) => ({
        invoiceId: r.invoice_id,
        code: r.code,
        kind: r.kind,
        customerName: r.customer_name,
        issueDate: r.issue_date,
        dueDate: r.due_date,
        daysOverdue: r.days_overdue,
        overdue: r.overdue,
        totalBase: r.total_base,
        settledBase: r.settled_base,
        openBase: r.open_base,
        paymentState: r.payment_state,
        isVoid: r.is_void,
        baseCurrency,
    }))

    return (
        <ListPage
            title={t('invoice.listTitle')}
            actions={
                <Link
                    href="/finance/invoices/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('invoice.new')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <InvoicesToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: total })}</p>

            <InvoicesTable rows={tableRows} empty={t('invoice.empty')} />

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
        </ListPage>
    )
}
