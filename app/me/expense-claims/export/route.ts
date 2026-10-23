// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · Q5):/me 上「expense-claims」那张表的统一导出 —— 服务端那一半。
// 页面只画最近 50 条并说出来;这里按页面【自己的】读取(../../meRows.ts)翻页取全,以 JSON 交给表。
// 门与页面同一个:只读【自己】的行(行级策略);一块车间大屏的会话、或不是员工的账号 → 拒绝。超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { mustCount } from '@/lib/db-helpers'
import { requireNotFloorDisplay } from '@/app/components/moduleGuard'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { myEmployeeId, myExpenseCount, myExpensePage, attachMyExpenseItems } from '../../meRows'

export async function GET() {
    if (await requireNotFloorDisplay()) return exportDenied()
    const supabase = await createClient()
    const employeeId = await myEmployeeId(supabase)
    if (!employeeId) return exportDenied()
    return exportRowsResponse({
        label: 'expense_claim_status (me)',
        count: async () => mustCount(await myExpenseCount(supabase, employeeId), 'expense_claim_status (me)'),
        page: (from, to) => myExpensePage(supabase, employeeId, from, to),
        shape: (rows) => attachMyExpenseItems(supabase, rows as { claim_id: string }[]),
    })
}
