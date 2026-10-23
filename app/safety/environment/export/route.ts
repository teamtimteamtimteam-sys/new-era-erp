// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-2 Q2):环境监测结果的统一导出 —— 服务端那一半。
// 页面只画最近 300 条并说出来;这里按页面【自己的】读取(../envRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(FN.safetyEnvironment);超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { envCount, envPage, shapeEnvRows } from '../envRows'

export async function GET() {
    if (!(await canEnter(FN.safetyEnvironment.permission))) return exportDenied()
    const supabase = await createClient()
    const canEdit = await can('module.safety.edit')
    return exportRowsResponse({
        label: 'environmental_result_rows',
        count: async () => mustCount(await envCount(supabase), 'environmental_result_rows'),
        page: (from, to) => envPage(supabase, from, to),
        shape: (rows) => shapeEnvRows(rows, canEdit),
    })
}
