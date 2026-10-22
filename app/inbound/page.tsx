// app/inbound/page.tsx
// 进料批次列表页:URL 驱动的搜索 / 阶段筛选 / 供应商筛选 / 物料筛选 / 排序 / 分页。
// 端口自 materials 列表,适配事务表:关联方(供应商/物料)用 FK-id 下拉,嵌入仅用于展示。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import InboundTable, { type InboundTableRow } from './InboundTable'
import InboundToolbar, { type PartyOption } from './InboundToolbar'
import { inboundCount, inboundPage, shapeInboundRows } from './inboundRows'
import {
    parseInboundListParams,
    parseInboundPage,
    resolveInboundSearchIds,
    buildInboundSearchOr,
    INBOUND_PAGE_SIZE,
} from './inboundQuery'
import { getTranslations } from '@/lib/i18n/server'
import StockWarningBanner from '@/app/components/inventory/StockWarningBanner'
import { mustCount, mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { can } from '@/lib/permissions'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { MOD } from '@/lib/modules'

// TABLE-EXPORT-1:行的类型、select、「库里的行 → 表的行」(含化验状态 · 定价申请 · 销毁证书 ·
// 仓库申请 · 来源三态)都搬进了 inboundRows.ts,与导出路由共用。注释随代码一起搬过去了。

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
        inboundCount(supabase, filterParams, searchOr),
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

    // 2) 取当前页的行:过滤 + 排序 + .range(FIX-2b 的「内嵌拿掉」注释随 select 搬进了 inboundRows.ts)
    const { data: batches, error } = await inboundPage(supabase, filterParams, searchOr, from, to)

    // ROLE-1 Batch 3b:收货与注销各有自己的码(库里 create_inbound_batch / soft_delete_inbound_batch 照样按码拒)
    const [canReceive, canWriteOff] = await Promise.all([can('action.receive_goods'), can('action.batch_write_off')])

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

    // CONV-1 的「在服务端压平成纯数据」—— 现在在 shapeInboundRows 里(TABLE-EXPORT-1 搬过去,原样)。
    const tableRows: InboundTableRow[] = await shapeInboundRows(supabase, batches ?? [], { materialNameById, supplierNameById })

    // 排序链接要带上的筛选参数(不含 sort/dir/page)—— 交给客户端那张表去拼 URL。
    const filterParamsForLinks = new URLSearchParams()
    if (q) filterParamsForLinks.set('q', q)
    if (stage) filterParamsForLinks.set('stage', stage)
    if (supplierId) filterParamsForLinks.set('supplier_id', supplierId)
    if (materialId) filterParamsForLinks.set('material_id', materialId)
    if (dateFrom) filterParamsForLinks.set('date_from', dateFrom)
    if (dateTo) filterParamsForLinks.set('date_to', dateTo)
    if (pricingStatus) filterParamsForLinks.set('pricing_status', pricingStatus)
    // TABLE-EXPORT-1 Q2:导出取【全部匹配行】—— 同一套筛选与排序,不带 page。
    const exportParams = new URLSearchParams(filterParamsForLinks)
    exportParams.set('sort', sort)
    exportParams.set('dir', dir)
    const exportHref = `/inbound/export?${exportParams.toString()}`

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
                <h1 className="mb-4">{t('inbound.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('inbound.loadError')}</p>
                    <details className="mt-2">
                        <summary className="cursor-pointer text-xs">{t('common.actionMessage.technicalDetail')}</summary>
                        <pre className="mt-1 text-xs">{JSON.stringify(error, null, 2)}</pre>
                    </details>
                </div>
            </div>
        )
    }

    return (
        <div className="p-8">
            {/* IOD-2:刚刚那次收货的落地告警(建批次成功、但有决定没人做过) */}
            <StockWarningBanner warn={sp.warn} />
            <div className="flex items-center justify-between mb-4">
                <h1 className="">{t('inbound.listTitle')}</h1>
                {/* FIX-1:这两个钮原本是 sm:hidden / hidden sm:inline-block ——
                    【互斥】的:桌面上现场收货那条路根本不出现,手机上完整录入
                    那条不出现。于是"从采购单收货"在桌面浏览器里没有任何入口,
                    而 --reach 也看不见:两个 <a> 都在 HTML 里,只是被 CSS 藏了。
                    可达性走查读的是标记,人读的是屏幕 —— 这是那道检查的盲区,
                    与 [id] 动态路由那条并列。现在两条路一直都在,并用下面那一行
                    说出它们的区别(而不是让人靠钮的名字猜)。 */}
                {/* ROLE-1 Batch 3b:建收货单归 action.receive_goods(仓库、管理员)。缺码时两个入口
                    都看得见、按不动 —— <Link> 禁不掉(fieldset 不管链接),所以挡住的那一支画真的
                    <Button disabled>,与 finance/invoices/[id] 的 PDF 钮同一个形状。 */}
                {canReceive ? (
                    <div className="flex items-center gap-2">
                        <Button asChild variant="outline">
                            <Link
                                href="/inbound/receive"
                            >
                                {t('receive.entry')}
                            </Link>
                        </Button>
                        <Button asChild>
                            <Link href="/inbound/new">{t('inbound.addButton')}</Link>
                        </Button>
                    </div>
                ) : (
                    <PermissionGate code="action.receive_goods" allowed={false} className="items-end">
                        <span className="flex items-center gap-2">
                            <Button variant="outline" disabled>{t('receive.entry')}</Button>
                            <Button disabled>{t('inbound.addButton')}</Button>
                        </span>
                    </PermissionGate>
                )}
            </div>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('inbound.twoPathsHint')}</p>

            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <InboundToolbar suppliers={supplierOptions} materials={materialOptions} />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
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
                canWriteOff={canWriteOff}
                exportHref={exportHref}
            />

            {/* 分页控件:服务端 <Link>,无额外客户端 JS;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('inbound.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('inbound.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-[color:var(--brand-muted-text)]">
                    {t('inbound.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('inbound.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" disabled>
                        {t('inbound.pagination.next')}
                    </Button>
                )}
            </div>
        </div>
    )
}
