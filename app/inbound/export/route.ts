// TABLE-EXPORT-1(Tim 2026-10-22 Q5):原来那条手写的 CSV 导出被统一导出取代。
// 本路由现在只做一件事:按页面【自己的】读取(inboundRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.inbound);超过 50,000 行按名拒绝(Q8)。
// 搜索同列表页:先解析关联方 id,再拼 OR(导出也要反映搜索)。
//
// ★ 旧 CSV 多出来的那几列(Unit · Unit Price · Notes)不在屏幕那张表上,所以不再导出(Q5:列只有表上那一份)。
//   其中 Unit Price 读的是 inbound_batches_masked,无权者那一格从前写成【空】—— 那条 Q3 要求的「Restricted」
//   因此没有一格可落:这张表上没有一列是被遮的。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseInboundListParams, resolveInboundSearchIds, buildInboundSearchOr } from '../inboundQuery'
import { inboundCount, inboundPage, shapeInboundRows, loadInboundNames } from '../inboundRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.inbound.permission))) return exportDenied()
    const params = parseInboundListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    const searchOr = buildInboundSearchOr(params.q, await resolveInboundSearchIds(supabase, params.q))
    return exportRowsResponse({
        label: 'inbound',
        count: async () => mustCount(await inboundCount(supabase, params, searchOr), 'inbound_batches'),
        page: (from, to) => inboundPage(supabase, params, searchOr, from, to),
        shape: async (rows) => shapeInboundRows(supabase, rows, await loadInboundNames(supabase)),
    })
}
