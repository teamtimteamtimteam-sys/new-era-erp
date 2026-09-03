// app/customers/page.tsx
// 客户列表页:URL 驱动的搜索 / 排序 / 分页(全部在服务端的 Supabase 查询里完成)。
// 端口自 suppliers 列表,去掉状态筛选(客户没有状态机)。
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import CustomerToolbar from './CustomerToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import CustomersTable, { type CustomerTableRow } from './CustomersTable'
import {
    parseCustomerListParams,
    parseCustomerPage,
    applyCustomerFilters,
    CUSTOMER_PAGE_SIZE,
    type CustomerSortCol,
} from './customerQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { mustRows } from '@/lib/db-helpers'

export default async function CustomersPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.customers)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, sort, dir } = parseCustomerListParams(sp)
    const requestedPage = parseCustomerPage(sp.page)
    const filterParams = { q, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前搜索是准确的)。head:true 只要 count 不要行。
    const { count } = await applyCustomerFilters(
        supabase.from('customers').select('id', { count: 'exact', head: true }),
        filterParams
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / CUSTOMER_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * CUSTOMER_PAGE_SIZE
    const to = from + CUSTOMER_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const baseQuery = supabase
        .from('customers')
        .select('id, code, legal_name, country, customer_types, status, created_at')

    const { data: customers, error } = await applyCustomerFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // PARTY-1:联系人搬进了 counterparty_contacts,一个客户可以有好几个 ——
    // 列表这一栏画的是【主联系人】那一行。分开一次查询是因为 PostgREST 的
    // 嵌套过滤在这里要不到"只要 is_primary 的那一行",而在 TS 里再筛一遍
    // 就是把一条筛选写两遍。
    const contactRows = mustRows(
        await supabase.from('counterparty_contacts')
            .select('customer_id, name, email, name_inferred')
            .in('customer_id', (customers ?? []).map((c) => c.id).length
                ? (customers ?? []).map((c) => c.id) : ['00000000-0000-0000-0000-000000000000'])
            .is('deleted_at', null).eq('is_primary', true),
        'counterparty_contacts') as { customer_id: string; name: string; email: string | null; name_inferred: boolean }[]
    const primaryByCustomer = new Map(contactRows.map((r) => [r.customer_id, r]))

    // 表头排序链接:点当前列翻转方向,点其它列默认升序;保留 q。不带 page —— 改排序回到第 1 页。
    function sortHref(col: CustomerSortCol) {
        const nextDir = sort === col && dir === 'asc' ? 'desc' : 'asc'
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        params.set('sort', col)
        params.set('dir', nextDir)
        return `/customers?${params.toString()}`
    }

    // 分页链接:保留当前的 q / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/customers?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('customers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('customers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ Q7:排序仍是服务端的(表头仍是链接),行为一个字没变。
    // ★ state 恒为 'ok' —— CustomerToolbar 与 /customers/overlap 入口都是真实出口;
    //   那条 overlap 链接【有冒烟可达性探针盯着】,删了当场红。
    const tableRows: CustomerTableRow[] = (customers ?? []).map((c) => {
        const p = primaryByCustomer.get(c.id)
        return {
            id: c.id,
            code: c.code,
            legalName: c.legal_name,
            country: c.country,
            contactName: p?.name ?? null,
            contactInferred: Boolean(p?.name_inferred),
            email: p?.email ?? '—',
            types: c.customer_types?.join(', ') ?? '',
            status: c.status,
            // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
            createdLabel: formatTimestamp(c.created_at, dateLocale),
        }
    })

    const filterQuery: Record<string, string> = {}
    if (q) filterQuery.q = q

    return (
        <ListPage
            title={t('customers.listTitle')}
            actions={
                <div className="flex items-center gap-3">
                    {/* ★【PARTY-1:重叠报告的入口 —— 这一页新建时【没有任何入口】★
                        本仓库为这件事付过两次账(SAL-B6 的客户详情页、FIX-1 的入库收货),
                        而 --reach 【查得到】静态路由,只是它要跑两小时。
                        入口放在客户列表上,因为"这家客户是不是也是我们的供应商"
                        正是在看客户名单的时候才会冒出来的问题。 */}
                    <Link href="/customers/overlap" className="text-sm text-blue-600 hover:underline">
                        {t('overlap.entryLink')}
                    </Link>
                    <Link
                        href="/customers/new"
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                    >
                        {t('customers.addButton')}
                    </Link>
                </div>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <CustomerToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('customers.recordCount', { count: total })}
            </p>

            <CustomersTable
                rows={tableRows}
                empty={t('customers.emptyState')}
                sort={sort}
                dir={dir}
                filterQuery={filterQuery}
                shown={tableRows.length}
                total={total}
            />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('customers.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('customers.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('customers.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('customers.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('customers.pagination.next')}
                    </span>
                )}
            </div>
        </ListPage>
    )
}
