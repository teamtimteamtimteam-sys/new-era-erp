// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):行内转账那张表的统一导出 —— 服务端那一半。
// 页面只画最近 50 笔并说出来;这里按页面【自己的】读取(../../transferRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
// ★ 路由不放在 /finance/bank/export:那一页还有别的表(对账状态卡片),这一条只属于转账那一张。
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { transferCount, transferPage, shapeTransferRows } from '../../transferRows'

export async function GET() {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'bank_transfers',
        count: async () => mustCount(await transferCount(supabase), 'bank_transfers'),
        page: (from, to) => transferPage(supabase, from, to),
        shape: (rows) => shapeTransferRows(supabase, rows),
    })
}
