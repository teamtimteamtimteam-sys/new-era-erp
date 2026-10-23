// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · 2026-10-23 TABLE-EXPORT-2b Q1):/operation/contamination「每班一格」那张表的统一导出 —— 服务端那一半。
// 页面画最新的 300 格;这里按页面【自己的】读取与映射(../../contaminationRows.ts · ../../checkRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(FN.contamination)。两张表各一条路由(理由同 /operation/capture/pending/export)。
import { createClient } from '@/lib/supabase/server'
import { getLocale } from '@/lib/i18n/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { gridCount, gridPage, shapeGridRows } from '../../contaminationRows'
import { labelsFor } from '../../checkRows'

export async function GET() {
    if (!(await canEnter(FN.contamination.permission))) return exportDenied()
    const supabase = await createClient()
    const locale = await getLocale()
    const [labels, canOpenRuns] = await Promise.all([labelsFor(supabase, locale), can('module.processing.view')])
    return exportRowsResponse({
        label: 'contamination_shift_status',
        count: async () => mustCount(await gridCount(supabase), 'contamination_shift_status'),
        page: (from, to) => gridPage(supabase, from, to),
        shape: (rows) => shapeGridRows(rows, labels, locale, canOpenRuns),
    })
}
