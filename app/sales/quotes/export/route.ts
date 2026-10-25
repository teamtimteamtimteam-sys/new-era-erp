// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):报价清单的统一导出 —— 服务端那一半。
// 页面只画最新 200 张并说出来;这里按页面【自己的】读取(../quotesRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.sales);超过 50,000 行按名拒绝。
// TABLE-FEATURES-1 Q9:读与页面同一份 `sort` / `dir`(quotesRows.ts 的 parseQuoteSort)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { quotesCount, quotesPage, parseQuoteSort } from '../quotesRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.sales.permission))) return exportDenied()
    const sort = parseQuoteSort(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'quote_status',
        count: async () => mustCount(await quotesCount(supabase), 'quote_status'),
        page: (from, to) => quotesPage(supabase, from, to, sort),
        shape: (rows) => rows,
    })
}
