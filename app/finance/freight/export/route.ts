// TABLE-EXPORT-2a(Tim 2026-10-22,TABLE-EXPORT-2 Q2):运费单据登记簿的统一导出 —— 服务端那一半。
// 页面只画最近 200 张并说出来;这里按页面【自己的】读取(../freightRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.finance);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { freightCount, freightPage, shapeFreightRows, parseFreightListParams } from '../freightRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(MOD.finance.permission))) return exportDenied()
    // TABLE-FEATURES-1 Q9:与页面同一份排序参数
    const params = parseFreightListParams(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    return exportRowsResponse({
        label: 'freight_documents',
        count: async () => mustCount(await freightCount(supabase), 'freight_documents'),
        page: (from, to) => freightPage(supabase, params, from, to),
        shape: (rows) => shapeFreightRows(rows),
    })
}
