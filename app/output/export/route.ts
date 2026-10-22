// TABLE-EXPORT-1(Tim 2026-10-22 Q5):原来那条手写的 CSV 导出被统一导出取代。
// 本路由现在只做一件事:按页面【自己的】读取(outputRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.output);超过 50,000 行按名拒绝(Q8)。
// 搜索同列表页:先解析关联方 id,再拼 OR(导出也要反映搜索)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseOutputListParams, resolveOutputSearchIds, buildOutputSearchOr } from '../outputQuery'
import { outputCount, outputPage, shapeOutputRows } from '../outputRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.output.permission))) return exportDenied()
    const params = parseOutputListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    const searchOr = buildOutputSearchOr(params.q, await resolveOutputSearchIds(supabase, params.q))
    return exportRowsResponse({
        label: 'output',
        count: async () => mustCount(await outputCount(supabase, params, searchOr), 'output_batches'),
        page: (from, to) => outputPage(supabase, params, searchOr, from, to),
        shape: (rows) => shapeOutputRows(supabase, rows),
    })
}
