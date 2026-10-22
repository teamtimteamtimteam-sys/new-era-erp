// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):分录【清单】的统一导出 —— 服务端那一半。
// ★ 不是 ../../export/route.ts(那是总账导出:一行一条分录行、必须给起止日,GLEXPORT-1,五条专用导出之一,版式不动)。
//   这一条导出的是清单本身:一行一张分录,列就是表上的列。
// 按页面【自己的】读取(../../journalRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
// 工资分录的金额对不持 data.view_pay 的人是 null(journal_lines_masked)—— 表的 exportAs 把它写成「受限」。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { parseJournalListParams, journalCount, journalPage, shapeJournalRows } from '../../journalRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    const params = parseJournalListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'journal_entries',
        count: async () => mustCount(await journalCount(supabase, params), 'journal_entries'),
        page: (from, to) => journalPage(supabase, params, from, to),
        shape: (rows) => shapeJournalRows(supabase, rows, false),
    })
}
