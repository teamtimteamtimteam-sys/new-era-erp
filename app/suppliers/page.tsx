// app/suppliers/page.tsx
// 供应商列表页:URL 驱动的搜索 / 状态筛选 / 排序(全部在服务端的 Supabase 查询里完成)
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import SupplierToolbar from './SupplierToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import SuppliersTable, { type SupplierTableRow } from './SuppliersTable'
import {
    parseSupplierListParams,
    parseSupplierPage,
    applySupplierFilters,
    SUPPLIER_PAGE_SIZE,
    type SupplierSortCol,
} from './supplierQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD, FN } from '@/lib/modules'

export default async function SuppliersPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        status?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    // 解析并校验 URL 参数(都给安全默认值)—— 与导出路由共用同一份逻辑
    const { q, status, sort, dir } = parseSupplierListParams(sp)
    const requestedPage = parseSupplierPage(sp.page)
    const filterParams = { q, status, sort, dir }

    // 1) 先取匹配总数(同样套用过滤,所以总页数对当前筛选是准确的)。head:true 只要 count 不要行。
    const { count } = await applySupplierFilters(
        supabase.from('suppliers').select('id', { count: 'exact', head: true }).neq('counterparty_type', 'forwarder'),
        filterParams
    )
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / SUPPLIER_PAGE_SIZE))
    // 把页码上钳到总页数(手输过大的 ?page= 时回落到最后一页,而不是空表)
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * SUPPLIER_PAGE_SIZE
    const to = from + SUPPLIER_PAGE_SIZE - 1

    // 2) 取当前页的行:过滤 + 排序后再 .range(from, to)
    const baseQuery = supabase
        .from('suppliers')
        .select(
            'id, code, legal_name, short_name, country, supplier_types, status, tax_id, created_at'
        )
        // LOG-1b:货代不进供应商名单(他们保留 supplier id 只为账上那条链)
        .neq('counterparty_type', 'forwarder')

    const { data: suppliers, error } = await applySupplierFilters(
        baseQuery,
        filterParams
    ).range(from, to)

    // 分页链接:保留当前的 q / status / sort / dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (status) params.set('status', status)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/suppliers?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('suppliers.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('suppliers.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ Q7:排序仍然是服务端的,表头仍然是链接(DataTable 的 sorting.mode='server',
    //   与 /inbound 同一个口子)。href 是函数,过不了 RSC 边界,所以这里只传参数。
    // ★ state 恒为 'ok' —— 筛选工具栏与那两条入口链接都是真实出口(§⑩-3);
    //   /contracts 与 /sales/commissions 两条链接【有冒烟可达性探针盯着】,删了当场红。
    const tableRows: SupplierTableRow[] = (suppliers ?? []).map((s) => ({
        id: s.id,
        code: s.code,
        legalName: s.legal_name,
        country: s.country,
        types: s.supplier_types?.join(', ') ?? '',
        status: s.status,
        // 时间戳按 locale 格式化在服务端做完 —— dateLocale 不过 RSC 边界
        createdLabel: formatTimestamp(s.created_at, dateLocale),
    }))

    const filterQuery: Record<string, string> = {}
    if (q) filterQuery.q = q
    if (status) filterQuery.status = status

    return (
        <ListPage
            title={t('suppliers.listTitle')}
            actions={
                // BTN-6:这一层 `flex items-center gap-3` 撤了 —— 外壳的动作槽
                // 现在就是 `flex flex-wrap items-center justify-end gap-3`,
                // 逐字同一套值,再包一层只是把同一件事写第二遍。
                <>
                    {/* ★【CONTRACT-1:合同登记簿的入口 —— 那一页建好时【没有任何入口】★
                        照 PARTY-1 的做法办:本仓库为「页面上线却走不到」付过两次账
                        (SAL-B6、FIX-1)。这条链接配一条冒烟可达性探针
                        (scripts/smoke-routes.mjs 里在 /suppliers 的 HTML 里找
                        /contracts)—— 把"我记得加了链接"换成机制。 */}
                    {/* ★★ BTN-6(2026-09-07):这两条【第二次转,这次留下来了】★★
                        BTN-5b 转过一次又退回来,理由是量出来的:转成 outline/sm 之后
                        /suppliers 在 390px 上溢出 20px(元凶就是这一行,行宽 378 / 视口 390)。
                        当时记的机制是「库按钮带 shrink-0,压不扁」——【那一半对,但不完整】:
                        真正被夺走的是【折行能力】(nowrap + min-width:auto),
                        而不是收缩能力;只拿掉 shrink-0 一个像素都不会动。
                        BTN-6 因此不改按钮,改【行】:ListPage 的动作槽现在有自己的
                        flex-wrap 容器(见 list-page.tsx 抬头),窄屏上这一行折到第二行。
                        ☞ R10 那条「不许在调用点加包装层」仍然成立,而且正是靠它:
                          修法留在外壳里,下一刀看得见;调用点这里一个包装层都没有。 */}
                    <Button asChild variant="outline" size="sm">
                        <Link href={FN.contracts.href}>{t('contracts.entryLink')}</Link>
                    </Button>
                    {/* ★【COMM-1:佣金协议的入口 —— 与上面那条逐字同一个理由】★ */}
                    <Button asChild variant="outline" size="sm">
                        <Link href={FN.commissions.href}>{t('commissions.entryLink')}</Link>
                    </Button>
                    <Button asChild>
                        <Link href="/suppliers/new">{t('suppliers.addButton')}</Link>
                    </Button>
                </>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <SupplierToolbar />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('suppliers.recordCount', { count: total })}
            </p>

            <SuppliersTable
                rows={tableRows}
                empty={t('suppliers.emptyState')}
                sort={sort}
                dir={dir}
                filterQuery={filterQuery}
                shown={tableRows.length}
                total={total}
            />

            {/* 分页控件:服务端 <Link>,无额外客户端 JS;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('suppliers.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('suppliers.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-gray-600">
                    {t('suppliers.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('suppliers.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('suppliers.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
