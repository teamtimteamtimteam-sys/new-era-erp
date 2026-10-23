// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):巡检记录清单的统一导出 —— 服务端那一半。
// 页面只画最近 200 次并说出来;这里按页面【自己的】读取(../../runRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(FN.safetyInspections);超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { runsCount, runsPage, shapeRunRows } from '../../runRows'

export async function GET() {
    if (!(await canEnter(FN.safetyInspections.permission))) return exportDenied()
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'inspection_run_rows',
        count: async () => mustCount(await runsCount(supabase), 'inspection_run_rows'),
        page: (from, to) => runsPage(supabase, from, to),
        shape: (rows) => shapeRunRows(rows),
    })
}
