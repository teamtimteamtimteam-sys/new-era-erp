// app/purchasing/orders/page.tsx
// 采购单列表:最新在前(order_date DESC),order_date 区间 + 供应商 + 状态筛选,
// count+range 分页(端口自发票列表)。
// 在册且未取消的走 purchase_order_status(带已预付/收货进度);【已取消的不在视图里】,
// 筛选状态为 cancelled 时另查 purchase_orders 本表(其预付/进度数字无意义,留空)。
// OPS-14:预付两列在没有 module.finance.view 时【也是 null】—— 于是 null 有两个含义,
// 「已取消所以无意义」与「你看不见」。前者画「—」,后者画「受限」,靠权限码分开。
// CCY-1:这张表里【并排两种币】——「估算总额」是采购单自己的币种(po.currency),
// 「已预付」与那个未抵扣角标是本位币(*_base)。列头一个币种也没写,两列挨着,
// 于是 12,000 与 8,100 看着像同一种钱。两列各自带上币种,不省。
import { mustRows } from '@/lib/db-helpers'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { loadPoCategoryAccess } from '@/lib/poCategoryAccess'
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { DatePresetLinks } from '@/app/components/ui/date-presets'
import { readDatePresets } from '@/lib/datePresetsServer'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import OrdersToolbar from './OrdersToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import OrdersTable, { type PurchaseOrderRow } from './OrdersTable'
import { parsePoListParams, poCount, poPage, shapePoRows, poExportHref, poTotals } from './orderRows'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { setSortParams } from '@/lib/listSort'

const PAGE_SIZE = 20

function parsePage(value: string | undefined): number {
    const n = Number(value)
    return Number.isInteger(n) && n >= 1 ? n : 1
}

export default async function PurchaseOrdersPage({
    searchParams,
}: {
    searchParams: Promise<{ date_from?: string; date_to?: string; supplier?: string; status?: string; page?: string; sort?: string; dir?: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.purchasing)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    // TABLE-EXPORT-1:读取与「库里的行 → 表的行」搬进 orderRows.ts,与导出路由共用一份。
    const params = parsePoListParams(sp)
    const listParams = params
    const { dateFrom, dateTo, supplier, status } = params
    const requestedPage = parsePage(sp.page)

    const { count } = await poCount(supabase, params)
    // TABLE-FEATURES-2(Tim 2026-10-25 Q1):表尾合计 —— 同一套筛选,所有符合的单,由库算
    const totals = await poTotals(supabase, params)
    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    // TABLE-EXPORT-1:读失败必须【失败】(mustRows)—— 此前 error 从没被解构过,一次失败会画成一张空表。
    const pageRows = mustRows(await poPage(supabase, params, (page - 1) * PAGE_SIZE, (page - 1) * PAGE_SIZE + PAGE_SIZE - 1), 'purchase orders')

    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (dateFrom) params.set('date_from', dateFrom)
        if (dateTo) params.set('date_to', dateTo)
        if (supplier) params.set('supplier', supplier)
        if (status) params.set('status', status)
        // TABLE-FEATURES-1 Q9:翻页保留排序
        setSortParams(params, listParams.sort)
        params.set('page', String(targetPage))
        return `/purchasing/orders?${params.toString()}`
    }

    // 工具栏的供应商选项
    // ★ FIX-2b:查名视图。工具栏那个供应商筛选此前对没有 module.suppliers.view
    //   的读者是【一张空下拉】—— 而表格里的供应商名是从视图带出来的、照常显示,
    //   于是屏幕自相矛盾:列里有六家供应商,筛选器里一家都没有。
    //   supplier_lookup 的谓词含 finance.view,列含 counterparty_type(筛货代要用)。
    const { data: supplierRows } = await supabase
        .from('supplier_lookup')
        .select('id, legal_name')
        .is('deleted_at', null)
        // LOG-1b:货代不进供应商名单
        .neq('counterparty_type', 'forwarder')
        .order('legal_name')
    // 视图列在生成类型里全可空;行进了视图即非空(WHERE 已保证)。
    const supplierOptions = ((supplierRows ?? []) as unknown as
        { id: string; legal_name: string }[]).map((s) => ({ id: s.id, name: s.legal_name }))

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ state 恒为 'ok' —— OrdersToolbar 是真实出口(§⑩-3)。
    const tableRows: PurchaseOrderRow[] = await shapePoRows(pageRows)

    const poAccess = await loadPoCategoryAccess(supabase)

    // TABLE-FEATURES-2 Q5:日期快捷区间(新加坡的今天 + 财年年末)在服务端算好,工具栏上方一排链接
    const presets = await readDatePresets(supabase)

    return (
        <ListPage
            title={t('purchasing.ordersTitle')}
            actions={
                /* ★ APR-10(Q6):开单要某一类的开单码 —— 一类都不持的人看得见这颗钮、按不动、说出码 */
                poAccess.any ? (
                    <Button asChild>
                        <Link href="/purchasing/orders/new">{t('purchasing.newOrder')}</Link>
                    </Button>
                ) : (
                    <PermissionGate code={Object.values(poAccess.codes).join(' · ')} allowed={false} inline>
                        <Button disabled>{t('purchasing.newOrder')}</Button>
                    </PermissionGate>
                )
            }
            state={{ kind: 'ok' }}
        >
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <DatePresetLinks presets={presets} fromKey="date_from" toKey="date_to" pageKey="page" />
                <OrdersToolbar suppliers={supplierOptions} />
            </Suspense>

            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">{t('finance.recordCount', { count: total })}</p>

            <OrdersTable rows={tableRows} empty={t('purchasing.empty')} exportHref={poExportHref(params)}
                         sort={params.sort} shown={tableRows.length} total={total} totals={totals} />

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
