// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · Q5):/me 上「leave-requests」那张表的统一导出 —— 服务端那一半。
// 页面只画最近 50 条并说出来;这里按页面【自己的】读取(../../meRows.ts)翻页取全,以 JSON 交给表。
// 门与页面同一个:只读【自己】的行(行级策略);一块车间大屏的会话、或不是员工的账号 → 拒绝。超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { mustCount } from '@/lib/db-helpers'
import { requireNotFloorDisplay } from '@/app/components/moduleGuard'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { myEmployeeId, myLeaveCount, myLeavePage, parseMyLeaveSort } from '../../meRows'

export async function GET(req: NextRequest) {
    if (await requireNotFloorDisplay()) return exportDenied()
    const supabase = await createClient()
    const employeeId = await myEmployeeId(supabase)
    if (!employeeId) return exportDenied()
    // TABLE-FEATURES-1 Q9:与页面上那张表同一个顺序(同一个参数前缀)
    const sort = parseMyLeaveSort(Object.fromEntries(req.nextUrl.searchParams))
    return exportRowsResponse({
        label: 'leave_requests_masked (me)',
        count: async () => mustCount(await myLeaveCount(supabase, employeeId), 'leave_requests_masked (me)'),
        page: (from, to) => myLeavePage(supabase, employeeId, sort, from, to),
        shape: (rows) => rows,
    })
}
