// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):「已冻结的预测」的统一导出 —— 服务端那一半。
// 页面只画最近 20 张并说出来;这里按页面【自己的】读取(../../frozenRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
// ★ 路由不放在 /finance/cash-forecast/export:那一页还有别的表(预测明细、经常性成本行),这一条只属于冻结登记簿。
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { frozenCount, frozenPage } from '../../frozenRows'

export async function GET() {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'cash_forecasts',
        count: async () => mustCount(await frozenCount(supabase), 'cash_forecasts'),
        page: (from, to) => frozenPage(supabase, from, to),
        shape: (rows) => rows,
    })
}
