// SO-1:销售订单列表。
//
// CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— 抬头「新建订单」住在
// actions 里(状态分支之前),空集由 DataTable 自己的 empty 说。
// 【入口与权限】本页守 MOD.finance —— module.sales.* 线上不存在(见
// salesOrderTypes.ts 抬头)。入口挂在财务子导航上,与该子导航其余各项同一对码,
// 这是 RPT-1 那条子导航规矩的前提;若将来订单改挂别的权限码,那个前提当场失效。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { soStatusKey } from './salesOrderTypes'
import { ListPage } from '@/app/components/ui/list-page'
import SalesOrdersTable, { type SalesOrderRow } from './SalesOrdersTable'

type Row = {
    id: string; code: string; order_date: string; status: string
    currency: string; customers: { code: string; legal_name: string } | null
}

export default async function SalesOrdersPage() {
    const denied = await requireModule(MOD.sales)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const rows = mustRows(
        await supabase
            .from('sales_orders')
            .select('id, code, order_date, status, currency, customers ( code, legal_name )')
            .is('deleted_at', null)
            .order('order_date', { ascending: false })
            .limit(200),
        'sales_orders'
    ) as unknown as Row[]

    const tableRows: SalesOrderRow[] = rows.map((r) => ({
        id: r.id,
        code: r.code,
        customerLabel: r.customers ? `${r.customers.code} — ${r.customers.legal_name}` : '—',
        // 日期按 locale 格式化在服务端做完 —— locale 不过 RSC 边界
        orderDateLabel: new Date(r.order_date).toLocaleDateString(locale === 'zh' ? 'zh-CN' : 'en-US'),
        statusLabel: t(soStatusKey(r.status)),
        currency: r.currency,
    }))

    return (
        <ListPage
            title={t('sales.listTitle')}
            actions={
                <Link href="/sales/orders/new"
                      className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">
                    {t('sales.newOrder')}
                </Link>
            }
            state={{ kind: 'ok' }}
        >
            <SalesOrdersTable rows={tableRows} empty={t('sales.empty')} />
        </ListPage>
    )
}
