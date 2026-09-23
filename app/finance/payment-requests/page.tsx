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
import { getTranslations, getLocale } from '@/lib/i18n/server'
import PaymentRequestsTable, { type PaymentRequestRow } from './PaymentRequestsTable'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'

const PAGE_SIZE = 20
// 与 db/tables/payment_requests.sql 的 status CHECK 同一组取值;'open' / 'all' 是本页的两个合集。
const STATUSES = ['submitted', 'approved', 'paid', 'rejected', 'withdrawn'] as const
const OPEN = ['submitted', 'approved']

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function PaymentRequestsPage({
    searchParams,
}: {
    searchParams: Promise<{ status?: string; page?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,放在任何查询之前。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const filter: string = sp.status === 'all' || (STATUSES as readonly string[]).includes(sp.status ?? '')
        ? (sp.status as string) : 'open'
    const statusSet = filter === 'open' ? OPEN : filter === 'all' ? null : [filter]
    const requestedPage = parsePage(sp.page)

    interface Chain { in(c: string, v: string[]): Chain }
    const applyFilters = <T,>(query: T): T => {
        let chain = query as unknown as Chain
        if (statusSet) chain = chain.in('status', statusSet)
        return chain as unknown as T
    }

    const total = mustCount(
        await applyFilters(supabase.from('payment_requests').select('id', { count: 'exact', head: true })),
        'payment requests count'
    )
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * PAGE_SIZE

    const rows = mustRows(
        await applyFilters(
            supabase
                .from('payment_requests')
                .select('id, code, kind, status, counterparty_type, supplier_id, employee_id, customer_id, amount_ccy, currency, created_at')
        )
            .order('created_at', { ascending: false })
            .range(from, from + PAGE_SIZE - 1),
        'payment requests'
    )

    const ids = (k: 'supplier_id' | 'employee_id' | 'customer_id') =>
        Array.from(new Set(rows.map((r) => r[k]).filter(Boolean))) as string[]
    const supplierIds = ids('supplier_id')
    const employeeIds = ids('employee_id')
    const customerIds = ids('customer_id')
    type NameRow = { id: string; legal_name: string }
    const none = Promise.resolve({ data: [] as NameRow[], error: null })
    const [supRes, empRes, cusRes] = await Promise.all([
        // 查名视图:这一页的门是 finance.view,基表挂的是各自模块(FIX-2a 那一课)。
        supplierIds.length ? supabase.from('supplier_lookup').select('id, legal_name').in('id', supplierIds) : none,
        employeeIds.length ? supabase.from('employee_lookup').select('id, legal_name').in('id', employeeIds) : none,
        customerIds.length ? supabase.from('customer_lookup').select('id, legal_name').in('id', customerIds) : none,
    ])
    const nameById = new Map<string, string>()
    for (const res of [supRes, empRes, cusRes]) {
        for (const n of mustRows(res, 'payee names') as unknown as NameRow[]) nameById.set(n.id, n.legal_name)
    }

    const tableRows: PaymentRequestRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        kind: r.kind,
        payee: nameById.get(r.supplier_id ?? r.employee_id ?? r.customer_id ?? '') ?? '—',
        amountCcy: r.amount_ccy,
        currency: r.currency,
        status: r.status,
        createdDate: formatDate(r.created_at, locale),
    }))

    const href = (status: string, p = 1) => {
        const params = new URLSearchParams()
        if (status !== 'open') params.set('status', status)
        if (p > 1) params.set('page', String(p))
        const q = params.toString()
        return q ? `/finance/payment-requests?${q}` : '/finance/payment-requests'
    }
    const filters = ['open', ...STATUSES, 'all']

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

            <PaymentRequestsTable rows={tableRows} empty={t('finance.paymentRequests.empty')} />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link href={href(filter, page - 1)}>{t('finance.pagination.prev')}</Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>{t('finance.pagination.prev')}</Button>
                )}
                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>
                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link href={href(filter, page + 1)}>{t('finance.pagination.next')}</Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>{t('finance.pagination.next')}</Button>
                )}
            </div>
        </ListPage>
    )
}
