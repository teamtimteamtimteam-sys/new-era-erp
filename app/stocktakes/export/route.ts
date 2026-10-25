// TABLE-EXPORT-1(Tim 2026-10-22 Q2):盘点单登记簿的统一导出 —— 服务端那一半。
// 本路由只做一件事:按页面【自己的】读取(stocktakeRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.stocktakes);超过 50,000 行按名拒绝(Q8)。
// 这一页没有筛选、排序是固定的(created_at 倒序),所以不读任何查询参数。
// TABLE-FEATURES-1 Q9:排序不再固定 —— 读与页面同一份 `sort` / `dir`(stocktakeRows.ts 的 parseStocktakeSort)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { stocktakeCount, stocktakePage, shapeStocktakeRows, parseStocktakeSort } from '../stocktakeRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.stocktakes.permission))) return exportDenied()
    const sort = parseStocktakeSort(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'stocktakes',
        count: async () => mustCount(await stocktakeCount(supabase), 'stocktakes'),
        page: (from, to) => stocktakePage(supabase, from, to, sort),
        shape: (rows) => shapeStocktakeRows(rows),
    })
}
