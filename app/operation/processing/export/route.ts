// TABLE-EXPORT-1(Tim 2026-10-22 Q2 · Q8):加工单列表的统一导出 —— 服务端分页的表,所以行从这里翻页取全。
// 本路由只做一件事:按页面【自己的】读取(processingRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.processing);超过 50,000 行按名拒绝(Q8)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseProcessingListParams } from '../../processingQuery'
import { processingCount, processingPage, shapeProcessingRows } from '../processingRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.processing.permission))) return exportDenied()
    const params = parseProcessingListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'processing_runs',
        count: async () => mustCount(await processingCount(supabase, params), 'processing_runs'),
        page: (from, to) => processingPage(supabase, params, from, to),
        shape: (rows) => shapeProcessingRows(supabase, rows),
    })
}
