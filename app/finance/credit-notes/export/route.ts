// TABLE-EXPORT-2a(Tim 2026-10-22 Q2 · Q8):贷项凭证列表的统一导出 —— 服务端那一半。
// 按页面【自己的】读取(../creditNoteRows.ts)翻页取全,以 JSON 交给表。守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { creditNoteCount, creditNotePage, shapeCreditNoteRows, parseCreditNoteListParams } from '../creditNoteRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    // TABLE-FEATURES-1 Q9:与页面同一份排序参数
    const params = parseCreditNoteListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'credit_notes',
        count: async () => mustCount(await creditNoteCount(supabase), 'credit_notes'),
        page: (from, to) => creditNotePage(supabase, params, from, to),
        shape: (rows) => shapeCreditNoteRows(supabase, rows),
    })
}
