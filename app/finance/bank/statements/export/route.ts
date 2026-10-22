// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):对账单列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../statementRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseStatementListParams, statementCount, statementPage, shapeStatementRows } from '../statementRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const params = parseStatementListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'bank_statements',
        count: async () => mustCount(await statementCount(supabase, params), 'bank_statements'),
        page: (from, to) => statementPage(supabase, params, from, to),
        shape: (rows) => shapeStatementRows(supabase, rows),
    })
}
