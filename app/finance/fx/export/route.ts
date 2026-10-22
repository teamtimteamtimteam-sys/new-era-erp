// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):汇率列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../fxRows.ts,筛选与排序是 ../fxQuery.ts 那一份)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseFxListParams } from '../fxQuery'
import { fxCount, fxPage, shapeFxRows } from '../fxRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const params = parseFxListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'fx_rates',
        count: async () => mustCount(await fxCount(supabase, params), 'fx_rates'),
        page: (from, to) => fxPage(supabase, params, from, to),
        shape: (rows) => shapeFxRows(rows),
    })
}
