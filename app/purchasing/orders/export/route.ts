// TABLE-EXPORT-1(Tim 2026-10-22 Q2 · Q8):采购单列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(orderRows.ts)翻页取全,以 JSON 交给表,由表按它自己的列定义写成 xlsx / csv
// (app/components/ui/table-export.tsx)。守卫与页面同一个判据(MOD.purchasing);超过 50,000 行按名拒绝。
// 金额的遮蔽(data.view_purchase_prices · module.finance.view)是 *_masked 视图给的,与屏幕同一条读取。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parsePoListParams, poCount, poPage, shapePoRows } from '../orderRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.purchasing.permission))) return exportDenied()
    const params = parsePoListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'purchase_orders',
        count: async () => mustCount(await poCount(supabase, params), 'purchase_orders'),
        page: (from, to) => poPage(supabase, params, from, to),
        shape: (rows) => shapePoRows(rows),
    })
}
