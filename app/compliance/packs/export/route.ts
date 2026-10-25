// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):冻下来的合规包清单的统一导出 —— 服务端那一半。
// 页面只画最新 300 份并说出来;这里按页面【自己的】读取(../packsRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(FN.compliancePacks);超过 50,000 行按名拒绝。
// TABLE-FEATURES-1 Q9:读与页面同一份 `sort` / `dir`(packsRows.ts 的 parsePackSort)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { packsCount, packsPage, shapePackRows, parsePackSort } from '../packsRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(FN.compliancePacks.permission))) return exportDenied()
    const sort = parsePackSort(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'compliance_packs',
        count: async () => mustCount(await packsCount(supabase), 'compliance_packs'),
        page: (from, to) => packsPage(supabase, from, to, sort),
        shape: (rows) => shapePackRows(supabase, rows),
    })
}
