// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):付款申请列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../requestRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseRequestFilter, requestCount, requestPage, shapeRequestRows } from '../requestRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const filter = parseRequestFilter(request.nextUrl.searchParams.get('status') ?? undefined)
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'payment_requests',
        count: async () => mustCount(await requestCount(supabase, filter), 'payment_requests'),
        page: (from, to) => requestPage(supabase, filter, from, to),
        shape: (rows) => shapeRequestRows(supabase, rows),
    })
}
