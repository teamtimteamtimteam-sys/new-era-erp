// TABLE-EXPORT-2b-1:金属行情列表的统一导出 —— 服务端那一半。页面服务端分页,一次只画 20 行;
// 这里按页面【自己的】读取(../metalPricesRows.ts)、同一套筛选与排序翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.pricing);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseMetalPricesListParams } from '../metalPricesQuery'
import { loadSubstances, payableOnly } from '../substanceQuery'
import { metalPricesCount, metalPricesPage, shapeMetalPriceRows } from '../metalPricesRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.pricing.permission))) return exportDenied()
    const supabase = await createClient()
    // 合法的 ?metal= 与页面同一份字典(PROC-4)
    const allowed = payableOnly(await loadSubstances(supabase)).map((s) => s.code)
    const p = parseMetalPricesListParams(Object.fromEntries(request.nextUrl.searchParams), allowed)
    return exportRowsResponse({
        label: 'metal_prices',
        count: async () => mustCount(await metalPricesCount(supabase, p), 'metal_prices'),
        page: (from, to) => metalPricesPage(supabase, p, from, to),
        shape: (rows) => shapeMetalPriceRows(rows),
    })
}
