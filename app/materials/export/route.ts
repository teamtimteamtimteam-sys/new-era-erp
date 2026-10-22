// TABLE-EXPORT-1(Tim 2026-10-22 Q5):原来那条手写的 CSV 导出被统一导出取代。
// 本路由现在只做一件事:按页面【自己的】读取(materialRows.ts)翻页取全,以 JSON 交给表,
// 由表按它自己的列定义写成 xlsx / csv(app/components/ui/table-export.tsx)。
// 守卫与页面同一个判据(MOD.materials);超过 50,000 行按名拒绝(Q8)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseMaterialListParams } from '../materialQuery'
import { materialCount, materialPage, shapeMaterialRows } from '../materialRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.materials.permission))) return exportDenied()
    const params = parseMaterialListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'materials',
        count: async () => mustCount(await materialCount(supabase, params), 'materials'),
        page: (from, to) => materialPage(supabase, params, from, to),
        shape: (rows) => shapeMaterialRows(supabase, rows),
    })
}
