// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):供应商对账单清单的统一导出 —— 服务端那一半。
// 页面只画最近 300 份并说出来;这里按页面【自己的】读取(../statementRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(FN.financeSupplierStatements = module.finance.view);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { statementCount, statementPage, shapeStatementRows, parseSupplierStatementListParams } from '../statementRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(FN.financeSupplierStatements.permission))) return exportDenied()
    // TABLE-FEATURES-1 Q9:与页面同一份排序参数
    const params = parseSupplierStatementListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'supplier_statement_rows',
        count: async () => mustCount(await statementCount(supabase), 'supplier_statement_rows'),
        page: (from, to) => statementPage(supabase, params, from, to),
        shape: (rows) => shapeStatementRows(rows),
    })
}
