// app/inbound/page.tsx
// 进料批次列表页:URL 驱动的搜索 / 阶段筛选 / 供应商筛选 / 物料筛选 / 排序 / 分页。
// 端口自 materials 列表,适配事务表:关联方(供应商/物料)用 FK-id 下拉,嵌入仅用于展示。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { formatTimestamp } from '@/lib/format'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import InboundTable, { type InboundTableRow } from './InboundTable'
import InboundToolbar, { type PartyOption } from './InboundToolbar'
import { STAGE_OPTIONS, labelKeyForValue } from './options'
import {
    parseInboundListParams,
    parseInboundPage,
    applyInboundFilters,
    resolveInboundSearchIds,
    buildInboundSearchOr,
    INBOUND_PAGE_SIZE,
} from './inboundQuery'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import StockWarningBanner from '@/app/components/inventory/StockWarningBanner'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { can } from '@/lib/permissions'
import { MOD } from '@/lib/modules'

// FK 嵌入运行时是对象;TS 默认猜数组(无生成 DB 类型),用显式类型 + cast 锁住。
type InboundRow = {
    id: string
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    arrival_date: string | null
    stage: string
    status: string
    pricing_status: string
    created_at: string
    // RECV-SOURCE-1:来源三态(采购行 / 理由 / 未说明)—— 列表列要用
    purchase_order_id: string | null
    purchase_order_line_id: string | null
    source_reason_code: string | null
    // FIX-2b:内嵌换成两个 FK —— 名字在 TS 里从查名视图拼(见 baseQuery 的注释)。
    material_id: string | null
    supplier_id: string | null
}

export default async function InboundPage({
    searchParams,
}: {
    // 本版本 Next 里 searchParams 是 Promise,需要 await
    searchParams: Promise<{
        q?: string
        stage?: string
        supplier_id?: string
        material_id?: string
        date_from?: string
        date_to?: string
        pricing_status?: string
        sort?: string
        dir?: string
        page?: string
        warn?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.inbound)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()
    const dateLocale = locale === 'zh' ? 'zh-CN' : 'en-US'

    const { q, stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir } =
        parseInboundListParams(sp)
    const requestedPage = parseInboundPage(sp.page)
    const filterParams = { q, stage, supplierId, materialId, dateFrom, dateTo, pricingStatus, sort, dir }

    // 跨关联方搜索:先查匹配 q 的物料/供应商 id(q 为空时零开销),再拼成本表 FK 列的 OR
    const searchIds = await resolveInboundSearchIds(supabase, q)
    const searchOr = buildInboundSearchOr(q, searchIds)

    // 1) 匹配总数(同样套用过滤 + 搜索;只 select 'id' 不带嵌入 —— 过滤都打在本表列上,无需 join)
    //    + 同时取供应商/物料下拉选项(独立查询,并行)。
    const [{ count }, suppliersRes, materialsRes, unpricedRes] = await Promise.all([
        applyInboundFilters(
            supabase.from('inbound_batches').select('id', { count: 'exact', head: true }),
            filterParams,
            searchOr
        ),
        // ★★【FIX-2b:两张下拉换读查名视图】★★ suppliers 的门是 module.suppliers.view、
        //   materials 的门是 module.materials.view,而本页的门是 module.inbound.view。
        //   实测(2026-09-06,模拟会话):Fu Sheng 从两张基表各读到 **0 行**,
        //   Phua 从 suppliers 读到 0 行 —— 于是这一页的两个筛选下拉对他们【整张是空的】,
        //   读起来是「系统里没有登记供应商 / 物料」。而这一页正是 Fu Sheng 每天的活。
        //   FIX-1 开的两张查名视图的谓词都含 module.inbound.view,列也够。
        supabase
            .from('supplier_lookup')
            // LOG-1b 的过滤【搬到 TS 侧】—— 见下面 supplierOptions 的理由:
            // 下拉要筛掉货代,而【名字表不能筛】。一次查询,两种用法。
            .select('id, legal_name, counterparty_type')
            .is('deleted_at', null)
            .order('legal_name'),
        supabase
            .from('material_lookup')
            .select('id, name')
            .is('deleted_at', null)
            .order('name'),
        // 未计价的在册批次数(cut 1 估值缺口提示;不做筛选入口,仅提示)
        supabase
            .from('inbound_batches_masked')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .is('unit_price', null),
    ])

    // 定价状态计数(cut 5b):等化验的批次 = 还没算对的钱,列表顶上要看得见
    const [unpricedStatusRes, provisionalRes] = await Promise.all([
        supabase
            .from('inbound_batches')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .eq('pricing_status', 'unpriced'),
        supabase
            .from('inbound_batches')
            .select('id', { count: 'exact', head: true })
            .is('deleted_at', null)
            .eq('pricing_status', 'provisional'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / INBOUND_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * INBOUND_PAGE_SIZE
    const to = from + INBOUND_PAGE_SIZE - 1

    // 2) 取当前页的行:带嵌入的 select(materials/suppliers 名字用于展示)+ 过滤 + 排序 + .range
    // ★★【FIX-2b:内嵌拿掉了 —— 它是同一条缺陷的第二半,而且更难看见】★★
    //   `materials ( name )` / `suppliers ( legal_name )` 是 PostgREST 的内嵌:
    //   它读的是【基表】,所以对 warehouse 与 operations 一律解析成 null,
    //   下面 tableRows 的 `?? '—'` 把它渲染成一根破折号。
    //   于是屏幕上是【一整列的破折号】—— 而破折号读起来是"这条记录没填",
    //   不是"你看不到"。名字改在 TS 里从两张查名视图拼(本仓库既有做法:
    //   「视图上不做 embed,分开查、在 TS 里拼」,见 /finance/expenses/new 的注释)。
    const baseQuery = supabase.from('inbound_batches').select(`
        id, code, quantity, unit, remaining_qty, arrival_date, stage, status, pricing_status, created_at,
        purchase_order_id, purchase_order_line_id, source_reason_code,
        material_id, supplier_id
    `)

    const { data, error } = await applyInboundFilters(
        baseQuery,
        filterParams,
        searchOr
    ).range(from, to)
    const batches = data as unknown as InboundRow[] | null

    // 本页各批次是否有"已记录未应用"的化验(cut 5b);只查当前页的 id —— 同
    // 采购单详情页取已抵扣额的做法
    const pageIds = (batches ?? []).map((b) => b.id)
    const { data: assayStatusRows } = pageIds.length
        ? await supabase
              .from('batch_assay_status')
              .select('inbound_batch_id, has_unapplied_assay')
              .in('inbound_batch_id', pageIds)
        : { data: [] as { inbound_batch_id: string | null; has_unapplied_assay: boolean | null }[] }
    const unappliedByBatch = new Set(
        (assayStatusRows ?? [])
            .filter((r) => r.has_unapplied_assay)
            .map((r) => r.inbound_batch_id ?? '')
    )

    // ── RECV-SOURCE-1:来源列的三态 ─────────────────────────────────────────────
    // 【未说明永远不是空白格】8 张早于本刀的无单收货按 R4 不回填,在这里必须
    // 读作【未说明】(琥珀),与"对着采购行"(蓝)与"有理由"(灰)看得出区别。
    // 理由标签从字典读、按语言选一个(GST-FIX-3);采购单号躲在
    // module.purchasing.view 后面(OPS-14),没有权限时给一句通用的"对着采购单",
    // 不让 RLS 丢行把"有单"渲染成别的东西。
    const canViewPurchasing = await can('module.purchasing.view')
    const poIds = [...new Set((batches ?? [])
        .filter((b) => b.purchase_order_line_id && b.purchase_order_id)
        .map((b) => b.purchase_order_id as string))]
    const poCodeById = new Map<string, string>()
    if (canViewPurchasing && poIds.length) {
        const poRes = await supabase.from('purchase_orders_masked').select('id, code').in('id', poIds)
        for (const r of mustRows(poRes, 'purchase_orders_masked')) {
            if (r.id && r.code) poCodeById.set(r.id, r.code)
        }
    }
    const reasonRes = await supabase
        .from('inbound_source_reasons').select('code, name_en, name_zh')
    const reasonLabelByCode = new Map(
        mustRows(reasonRes, 'inbound_source_reasons')
            .map((r) => [r.code, locale === 'zh' ? r.name_zh : r.name_en])
    )

    // 下拉选项:供应商按 legal_name、物料按 name 作为显示标签
    // 视图列在生成类型里全可空;行进了视图即非空(WHERE 已保证)。
    const supplierRows = mustRows(suppliersRes) as unknown as
        { id: string; legal_name: string; counterparty_type: string }[]
    const materialOptions: PartyOption[] = (mustRows(materialsRes) as unknown as
        { id: string; name: string }[]).map((m) => ({
        id: m.id,
        label: m.name,
    }))
    // ★★【FIX-2b fu2:【名字表】不能继承下拉的货代过滤】★★
    //   下拉排除货代是对的(LOG-1b:货代不进供应商名单)。但把那份【已经筛过的】
    //   清单直接当名字表用,会让一条【从货代收来的】批次印一根破折号 ——
    //   而这一刀存在的全部理由就是消灭那种破折号。
    //   实测(2026-09-06):今天这样的批次有 **0 条**,所以屏幕上看不出来。
    //   ★ 那正是它必须现在修的理由:一个要等数据长出来才显形的缺陷,
    //     不会有人把它和这一刀联系起来。
    //   所以:名字表取【全部】,货代只在下拉那一步筛掉。
    const supplierNameById = new Map(supplierRows.map((s) => [s.id, s.legal_name]))
    const materialNameById = new Map(materialOptions.map((o) => [o.id, o.label]))
    const supplierOptions: PartyOption[] = supplierRows
        .filter((s) => s.counterparty_type !== 'forwarder')
        .map((s) => ({ id: s.id, label: s.legal_name }))

    // stage 存储值反查成本地化文案;未知值原样显示
    const stageLabel = (value: string) => {
        const key = labelKeyForValue(STAGE_OPTIONS, value)
        return key ? t(key) : value
    }

    // ── CONV-1:把这一页要显示的东西【在服务端压平成纯数据】───────────────────
    //   来源那一列要三样服务端才知道的东西(采购单号 / 理由字典的本地化名字 /
    //   两样都没有 = 未说明),阶段标签要 options 的反查。都在这里算完,
    //   客户端只拿到「这一格该显示什么」。理由见 InboundTable.tsx 的抬头。
    const tableRows: InboundTableRow[] = (batches ?? []).map((b) => {
        const poCode = b.purchase_order_line_id
            ? (poCodeById.get(b.purchase_order_id ?? '') ?? t('inbound.source.fromPo'))
            : null
        return {
            id: b.id,
            code: b.code,
            // FIX-2b:名字来自两张查名视图(上面那两次查询),不再来自内嵌。
            // 拼不上仍然是 '—',但那时它的含义回到了【真的没有这一项】:
            // 权限那一半已经在视图的谓词里答过了。
            materialName: (b.material_id ? materialNameById.get(b.material_id) : null) ?? '—',
            supplierName: (b.supplier_id ? supplierNameById.get(b.supplier_id) : null) ?? '—',
            sourceKind: b.purchase_order_line_id ? 'po' : b.source_reason_code ? 'reason' : 'unexplained',
            sourceLabel: b.purchase_order_line_id
                ? poCode
                : b.source_reason_code
                  ? (reasonLabelByCode.get(b.source_reason_code) ?? b.source_reason_code)
                  : null,
            quantity: b.quantity,
            remaining: b.remaining_qty,
            unit: b.unit,
            arrivalDate: b.arrival_date,
            stageLabel: stageLabel(b.stage),
            status: b.status,
            pricingStatus: b.pricing_status,
            hasUnappliedAssay: unappliedByBatch.has(b.id),
            createdLabel: formatTimestamp(b.created_at, dateLocale),
        }
    })

    // 排序链接要带上的筛选参数(不含 sort/dir/page)—— 交给客户端那张表去拼 URL。
    const filterParamsForLinks = new URLSearchParams()
    if (q) filterParamsForLinks.set('q', q)
    if (stage) filterParamsForLinks.set('stage', stage)
    if (supplierId) filterParamsForLinks.set('supplier_id', supplierId)
    if (materialId) filterParamsForLinks.set('material_id', materialId)
    if (dateFrom) filterParamsForLinks.set('date_from', dateFrom)
    if (dateTo) filterParamsForLinks.set('date_to', dateTo)
    if (pricingStatus) filterParamsForLinks.set('pricing_status', pricingStatus)

    // 【sortHref 删掉了】它此前拼的那条链接现在由 InboundTable 拼 ——
    // 判据一个字没变(保留全部筛选、只改 sort/dir、不带 page),
    // 换的是它住在哪一侧。留一个没有调用者的函数,是下一个人据以断定
    // 「排序链接在这里拼」的东西。


    // 分页链接:保留所有筛选 + sort/dir,只改 page
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (q) params.set('q', q)
        if (stage) params.set('stage', stage)
        if (supplierId) params.set('supplier_id', supplierId)
        if (materialId) params.set('material_id', materialId)
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (pricingStatus) params.set('pricing_status', pricingStatus)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/inbound?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('inbound.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            {/* IOD-2:刚刚那次收货的落地告警(建批次成功、但有决定没人做过) */}
            <StockWarningBanner warn={sp.warn} />
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-2xl font-bold">{t('inbound.listTitle')}</h1>
                {/* FIX-1:这两个钮原本是 sm:hidden / hidden sm:inline-block ——
                    【互斥】的:桌面上现场收货那条路根本不出现,手机上完整录入
                    那条不出现。于是"从采购单收货"在桌面浏览器里没有任何入口,
                    而 --reach 也看不见:两个 <a> 都在 HTML 里,只是被 CSS 藏了。
                    可达性走查读的是标记,人读的是屏幕 —— 这是那道检查的盲区,
                    与 [id] 动态路由那条并列。现在两条路一直都在,并用下面那一行
                    说出它们的区别(而不是让人靠钮的名字猜)。 */}
                <div className="flex items-center gap-2">
                    <Link
                        href="/inbound/receive"
                        className="border border-blue-600 text-blue-600 px-4 py-2 rounded hover:bg-blue-50"
                    >
                        {t('receive.entry')}
                    </Link>
                    <Button asChild>
                        <Link href="/inbound/new">{t('inbound.addButton')}</Link>
                    </Button>
                </div>
            </div>
            <p className="text-sm text-gray-500 mb-4">{t('inbound.twoPathsHint')}</p>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <InboundToolbar suppliers={supplierOptions} materials={materialOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('inbound.recordCount', { count: total })}
                {(mustCount(unpricedRes)) > 0 && (
                    <span className="ml-2 text-gray-400">
                        {t('inbound.unpricedBadge', { n: mustCount(unpricedRes) })}
                    </span>
                )}
                {/* 等化验/暂定价的批次数(cut 5b):这些批次的应付金额还不是最终数 */}
                {((mustCount(unpricedStatusRes)) > 0 || (mustCount(provisionalRes)) > 0) && (
                    <span className="ml-2 text-gray-400">
                        {t('assay.awaitingFinal', {
                            unpriced: mustCount(unpricedStatusRes),
                            provisional: mustCount(provisionalRes),
                        })}
                    </span>
                )}
            </p>

            {/* ★★【CONV-1:13 列的手写 <table> 换成 DataTable】★★
                【行为一个字没变 —— Tim 的 Q7=A】排序仍然是数据库对【全体】排
                (server 模式:表头是链接,客户端一行都不重排),分页仍然是下面那组
                服务端 .range 链接。换的是外观与【手机上的形态】。
                【顺带修掉一处 off-by-one】此前空态那一行写的是 colSpan={12},
                而表头有 13 列 —— 空行少跨一格。DataTable 的 colSpan 是从列表算出来的,
                这一族的错从此写不进来。 */}
            <InboundTable
                rows={tableRows}
                sort={sort}
                dir={dir}
                filterQuery={filterParamsForLinks.toString()}
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
                        {t('inbound.pagination.prev')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('inbound.pagination.prev')}
                    </span>
                )}

                <span className="text-sm text-gray-600">
                    {t('inbound.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Link
                        href={pageHref(page + 1)}
                        className="rounded border border-gray-300 bg-white px-3 py-2 text-sm hover:bg-gray-50"
                    >
                        {t('inbound.pagination.next')}
                    </Link>
                ) : (
                    <span className="rounded border border-gray-200 bg-gray-100 px-3 py-2 text-sm text-gray-400">
                        {t('inbound.pagination.next')}
                    </span>
                )}
            </div>
        </div>
    )
}
