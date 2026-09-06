// app/output/page.tsx
// 产出批次列表页:URL 驱动的搜索 / 状态筛选 / 客户筛选 / 物料筛选 / 排序 / 分页。
// 端口自 inbound 列表:supplier→customer、stage→state。customer_id 可空(未售出批次无客户)。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import DeleteButton from './DeleteButton'
import OutputToolbar, { type PartyOption } from './OutputToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import OutputTable, { type OutputTableRow } from './OutputTable'
import { STATE_OPTIONS, labelKeyForValue } from '../inbound/options'
import {
    parseOutputListParams,
    parseOutputPage,
    applyOutputFilters,
    resolveOutputSearchIds,
    buildOutputSearchOr,
    OUTPUT_PAGE_SIZE,
    type OutputSortCol,
} from './outputQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import StockWarningBanner from '@/app/components/inventory/StockWarningBanner'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
// customers 可空:库存中的批次还没指派客户。
type OutputRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    state: string
    status: string
    created_at: string
    materials: { name: string } | null
    customers: { legal_name: string } | null
    // PROC-WIRE-1A:【另一条轴】—— 这批是干什么用的。是否可售【由字典那一列回答】,
    // 不由把码写死在这里回答,否则多一种不可售用途就要改代码。
    output_batch_purposes: { name_en: string; name_zh: string; is_saleable_stock: boolean } | null
}

export default async function OutputPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        state?: string
        customer_id?: string
        material_id?: string
        date_from?: string
        date_to?: string
        sort?: string
        dir?: string
        page?: string
        warn?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.output)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { q, state, customerId, materialId, dateFrom, dateTo, sort, dir } = parseOutputListParams(sp)
    const requestedPage = parseOutputPage(sp.page)
    const filterParams = { q, state, customerId, materialId, dateFrom, dateTo, sort, dir }

    // 跨关联方搜索:先查匹配 q 的物料/客户 id(q 为空时零开销),再拼成本表 FK 列的 OR
    const searchIds = await resolveOutputSearchIds(supabase, q)
    const searchOr = buildOutputSearchOr(q, searchIds)

    // 1) 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
    //    + 同时取客户/物料下拉选项(独立查询,并行)。
    const [{ count }, customersRes, materialsRes] = await Promise.all([
        applyOutputFilters(
            supabase.from('output_batches').select('id', { count: 'exact', head: true }),
            filterParams,
            searchOr
        ),
        supabase
            .from('customer_lookup')
            .select('id, legal_name')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('material_lookup')
            .select('id, name')
            .is('deleted_at', null)
            .order('name'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / OUTPUT_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * OUTPUT_PAGE_SIZE
    const to = from + OUTPUT_PAGE_SIZE - 1

    // 2) 取当前页的行:带嵌入的 select(materials/customers 名字用于展示)+ 过滤 + 排序 + .range
    const baseQuery = supabase.from('output_batches').select(`
        id, code, quantity, unit, remaining_qty, output_date, state, status, created_at,
        materials ( name ),
        customers ( legal_name ),
        output_batch_purposes ( name_en, name_zh, is_saleable_stock )
    `)

    // ── 这里【故意】没有"有未应用化验"的角标(PROC-1c 记,2026-08-12)──────────
    // 进料列表有一个(app/inbound/page.tsx,读 batch_assay_status.has_unapplied_assay)。
    // 产出侧没有,而这是一次判断,不是漏掉的一件事 —— 写在这里,是因为下一个人
    // 会在这一行附近发现这个不对称,而"为什么没有"只有写在缺口本身上才拦得住
    // 一次顺手补齐。
    //
    // 两侧的未应用化验【后果不同】:
    //   * 进料:化验一应用就重述应付 —— 未应用 = 这批货的单价还是错的,是钱。
    //     钱要在【列表】上就看得见,因为看列表的人正是在挑"哪一批该动"。
    //   * 产出:产出化验不定价(没有一张应付可重述)。未应用 = 含量、回收率与
    //     metal_value 分摊读的还是旧数,金额一分不动,要动也得有人显式重跑分摊。
    //     而批次页【已经在说这件事】了(OutputAssaySection 顶上的琥珀色横幅)。
    //
    // 所以这不是"进料有、产出该跟上",是两种后果各自配了合适的位置。真要补,
    // 代价也不是加一个 <span>:batch_assay_status 是进料专用视图(它的每一行都是
    // 一个 inbound_batch),产出侧要么新建一个同形视图,要么把它改成双父 ——
    // 那是一次机制改动,该有它自己的一刀和自己的理由,不该混在一次显示改动里。
    const { data, error } = await applyOutputFilters(
        baseQuery,
        filterParams,
        searchOr
    ).range(from, to)
    const batches = data as unknown as OutputRow[] | null

    // 下拉选项:客户按 legal_name、物料按 name 作为显示标签
    // 视图列在生成类型里一律可空;行进了视图即非空 —— 取用处本地锁死。
    const customerOptions: PartyOption[] = (mustRows(customersRes) as unknown as
        { id: string; legal_name: string }[]).map((c) => ({
        id: c.id,
        label: c.legal_name,
    }))
    const materialOptions: PartyOption[] = (mustRows(materialsRes) as unknown as
        { id: string; name: string }[]).map((m) => ({
        id: m.id,
        label: m.name,
    }))

    // state 存储值反查成本地化文案;未知值原样显示
    const stateLabel = (value: string) => {
        const key = labelKeyForValue(STATE_OPTIONS, value)
        return key ? t(key) : value
    }

    // 表头排序链接:保留所有筛选,只改 sort/dir;不带 page —— 改排序回到第 1 页。
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (state) params.set('state', state)
        if (customerId) params.set('customer_id', customerId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/output?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('output.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('output.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ Q7:排序仍是服务端的。★ state 恒为 'ok' —— OutputToolbar 是真实出口。
    const tableRows: OutputTableRow[] = (batches ?? []).map((b) => ({
        id: b.id,
        code: b.code,
        materialName: b.materials?.name ?? '—',
        customerName: b.customers?.legal_name ?? '—',
        quantity: `${b.quantity} ${b.unit}`,
        remaining: `${b.remaining_qty} ${b.unit}`,
        outputDate: b.output_date ?? '—',
        stateLabel: stateLabel(b.state),
        // PROC-WIRE-1A:用途角标的语言在服务端选好;可售的批次没有这个角标
        purposeTag:
            b.output_batch_purposes && !b.output_batch_purposes.is_saleable_stock
                ? (locale === 'zh' ? b.output_batch_purposes.name_zh : b.output_batch_purposes.name_en)
                : null,
        status: b.status,
        createdLabel: formatTimestamp(b.created_at, dateLocale),
    }))

    // 排序链接要原样带上的筛选参数 —— 【URL 名,不是变量名】,
    // 与转换前那个 sortHref 逐字一致(customer_id / material_id / date_from / date_to)。
    const filterQuery: Record<string, string> = {}
    if (q) filterQuery.q = q
    if (state) filterQuery.state = state
    if (customerId) filterQuery.customer_id = customerId
    if (materialId) filterQuery.material_id = materialId
    if (dateFrom) filterQuery.date_from = dateFrom
    if (dateTo) filterQuery.date_to = dateTo

    return (
        <ListPage
            title={t('output.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/output/new">{t('output.addButton')}</Link>
                </Button>
            }
            notices={
                /* IOD-2:刚刚那次建批次的落地告警(成功、但有决定没人做过)。
                   它要【无条件】出现 —— 一条只在有行时才画的告警等于没有告警。 */
                <StockWarningBanner warn={sp.warn} />
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <OutputToolbar customers={customerOptions} materials={materialOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('output.recordCount', { count: total })}
            </p>

            <OutputTable
                rows={tableRows}
                empty={t('output.emptyState')}
                sort={sort}
                dir={dir}
                filterQuery={filterQuery}
                shown={tableRows.length}
                total={total}
            />

            {/* 分页控件:服务端 <Link>,无额外客户端 JS;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Link
                        href={pageHref(page - 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('output.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('output.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('output.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('output.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('output.pagination.next')}
                    </span>
                )}
            </div>
        </ListPage>
    )
}
