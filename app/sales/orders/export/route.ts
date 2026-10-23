// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):销售订单清单的统一导出 —— 服务端那一半。
// 页面只画最新 200 张并说出来;这里按页面【自己的】读取(../ordersRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.sales);超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { ordersCount, ordersPage, shapeOrderRows } from '../ordersRows'

export async function GET() {
    if (!(await canEnter(MOD.sales.permission))) return exportDenied()
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'sales_orders',
        count: async () => mustCount(await ordersCount(supabase), 'sales_orders'),
        page: (from, to) => ordersPage(supabase, from, to),
        shape: (rows) => shapeOrderRows(rows),
    })
}
