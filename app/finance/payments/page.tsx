// app/finance/payments/page.tsx
// 收付款列表:最新在前,payment_date 日期区间 + 方向筛选 + count+range 分页
// (端口自分录列表)。往来单位名按页小批量反查(客户/供应商两次 .in)。
//
// CONV-4:套 CONV-1 的两文件模板。state 恒为 'ok' —— 筛选工具栏是真实出口。
import { Suspense } from 'react'
import { getBaseCurrency } from '@/lib/currency'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { parseDateRange } from '@/lib/dateFilter'
import PaymentsToolbar from './PaymentsToolbar'
import PaymentsTable, { type PaymentRow } from './PaymentsTable'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function PaymentsListPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; direction?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()
    const t = await getTranslations()

    const { dateFrom, dateTo } = parseDateRange(sp)
    const direction = sp.direction === 'in' || sp.direction === 'out' ? sp.direction : ''
    const requestedPage = parsePage(sp.page)

    // 过滤链(payments 不可变表,无软删)。最小链式子集,避免 supabase 深泛型。
    interface Chain {
        gte(c: string, v: string): Chain
        lte(c: string, v: string): Chain
        eq(c: string, v: string): Chain
    }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (dateFrom) chain = chain.gte('payment_date', dateFrom)
        if (dateTo) chain = chain.lte('payment_date', dateTo)
        if (direction) chain = chain.eq('direction', direction)
        return chain as unknown as T
    }

    // 1) 匹配总数
    const { count } = await applyFilters(
        supabase.from('payments').select('id', { count: 'exact', head: true })
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE
    const to = from + PAGE_SIZE - 1

    // 2) 取当前页(创建序最新在前)
    const { data: payments, error } = await applyFilters(
        supabase
            .from('payments')
            .select('id, code, direction, customer_id, supplier_id, amount_ccy, currency, amount_base, bank_account_code, payment_date, status')
    )
        .order('created_at', { ascending: false })
        .range(from, to)

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.paymentsTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const rows = payments ?? []

    // 3) 往来单位名(页级两次小 .in)
    const customerIds = Array.from(new Set(rows.map((r) => r.customer_id).filter(Boolean))) as string[]
    const supplierIds = Array.from(new Set(rows.map((r) => r.supplier_id).filter(Boolean))) as string[]
    const [customersRes, suppliersRes] = await Promise.all([
        customerIds.length
            ? supabase.from('customers').select('id, legal_name').in('id', customerIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
        supplierIds.length
            ? // LOG-1b:【这一处绝不过滤 counterparty_type】—— 它把 id 换成名字,不是选择器。
              //         过滤它会让【货代那几笔运费付款】的收款方名字变成空白,
              //         而那正是本模块存在的理由。
              supabase.from('suppliers').select('id, legal_name').in('id', supplierIds)
            : Promise.resolve({ data: [] as { id: string; legal_name: string }[], error: null }),
    ])
    const nameById = new Map<string, string>()
    for (const c of mustRows(customersRes)) nameById.set(c.id, c.legal_name)
    for (const s of mustRows(suppliersRes)) nameById.set(s.id, s.legal_name)

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (direction) params.set('direction', direction)
        params.set('page', String(targetPage))
        return `/finance/payments?${params.toString()}`
    }

    const tableRows: PaymentRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        paymentDate: r.payment_date,
        direction: r.direction,
        counterparty: nameById.get(r.customer_id ?? r.supplier_id ?? '') ?? '—',
        amountCcy: r.amount_ccy,
        currency: r.currency,
        amountBase: r.amount_base,
        baseCurrency,
        bankAccountCode: r.bank_account_code,
        status: r.status,
    }))

    return (
        <ListPage
            title={t('finance.paymentsTitle')}
            actions={
                <Link
                    href="/finance/payments/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('finance.recordPayment')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <PaymentsToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.recordCount', { count: total })}
            </p>

            <PaymentsTable rows={tableRows} empty={t('finance.paymentsEmpty')} />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
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
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
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
