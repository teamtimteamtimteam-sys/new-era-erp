// TABLE-EXPORT-2b-1(Tim 2026-10-23 TABLE-EXPORT-2b Q1):导入历史的统一导出 —— 服务端那一半。
// 页面只画最近 20 次并说出来;这里按页面【自己的】读取(../../importRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(action.bulk_import);超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { can } from '@/lib/permissions'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { importsCount, importsPage, shapeImportRows } from '../../importRows'

export async function GET() {
    if (!(await can('action.bulk_import'))) return exportDenied()
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'import_batches',
        count: async () => mustCount(await importsCount(supabase), 'import_batches'),
        page: (from, to) => importsPage(supabase, from, to),
        shape: (rows) => shapeImportRows(supabase, rows),
    })
}
