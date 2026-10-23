// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):请假申请清单的统一导出 —— 服务端那一半。
// 页面只画最新 300 条并说出来;这里按页面【自己的】读取与筛选(../leaveRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.hr);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { leaveCount, leaveFilterFrom, leavePage, shapeLeaveRows } from '../leaveRows'

export async function GET(req: NextRequest) {
    if (!(await canEnter(MOD.hr.permission))) return exportDenied()
    const supabase = await createClient()
    const f = leaveFilterFrom(req.nextUrl.searchParams)
    return exportRowsResponse({
        label: 'leave_requests_masked',
        count: async () => mustCount(await leaveCount(supabase, f), 'leave_requests_masked'),
        page: (from, to) => leavePage(supabase, f, from, to),
        shape: (rows) => shapeLeaveRows(supabase, rows),
    })
}
