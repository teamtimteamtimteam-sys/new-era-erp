// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):开支列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../expenseRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseExpenseListParams, resolveExpenseFilter, expenseCount, expensePage, shapeExpenseRows } from '../expenseRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const supabase = await createClient()
    const filter = await resolveExpenseFilter(supabase, parseExpenseListParams(Object.fromEntries(request.nextUrl.searchParams)))
    return exportRowsResponse({
        label: 'expenses',
        count: async () => mustCount(await expenseCount(supabase, filter), 'expenses'),
        page: (from, to) => expensePage(supabase, filter, from, to),
        shape: (rows) => shapeExpenseRows(supabase, rows),
    })
}
