// SO-1:销售订单列表。
//
// CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 抬头「新建订单」住在
// actions 里(状态分支之前),空集由 DataTable 自己的 empty 说。
// 【入口与权限】本页守 MOD.finance —— module.sales.* 线上不存在(见
// salesOrderTypes.ts 抬头)。入口挂在财务子导航上,与该子导航其余各项同一对码,
// 这是 RPT-1 那条子导航规矩的前提;若将来订单改挂别的权限码,那个前提当场失效。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import SalesOrdersTable from './SalesOrdersTable'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { ORDERS_SHOWN, ordersCount, ordersPage, shapeOrderRows } from './ordersRows'

export default async function SalesOrdersPage() {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const t = await getTranslations()
    const supabase = await createClient()

    // ★ TABLE-EXPORT-2b-2(Tim Q2):清单的读取与映射搬进 ordersRows.ts,与导出路由共用;只画最新 ORDERS_SHOWN 张,而且说出来。
    const [listRes, totalRes] = await Promise.all([ordersPage(supabase, 0, ORDERS_SHOWN - 1), ordersCount(supabase)])
    const tableRows = await shapeOrderRows(mustRows(listRes, 'sales_orders'))
    const total = mustCount(totalRes, 'sales_orders count')

    return (
        <ListPage
            title={t('sales.listTitle')}
            actions={
                <Button asChild>
                    <Link href="/sales/orders/new">{t('sales.newOrder')}</Link>
                </Button>
            }
            state={{ kind: 'ok' }}
        >
            <RowCapNotice shown={tableRows.length} total={total} />
            <SalesOrdersTable rows={tableRows} empty={t('sales.empty')} />
        </ListPage>
    )
}
