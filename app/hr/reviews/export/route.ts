// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):绩效评估清单的统一导出 —— 服务端那一半。
// 页面只画最新 200 份并说出来;这里按页面【自己的】读取与筛选(../reviewsRows.ts)翻页取全,以 JSON 交给表。
// 守卫与页面同一个判据(MOD.hr);超过 50,000 行按名拒绝。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { reviewsCount, reviewsFilterFrom, reviewsPage, shapeReviewRows } from '../reviewsRows'

export async function GET(req: NextRequest) {
    if (!(await canEnter(MOD.hr.permission))) return exportDenied()
    const supabase = await createClient()
    const f = reviewsFilterFrom(req.nextUrl.searchParams)
    return exportRowsResponse({
        label: 'performance_reviews_masked',
        count: async () => mustCount(await reviewsCount(supabase, f), 'performance_reviews_masked'),
        page: (from, to) => reviewsPage(supabase, f, from, to),
        shape: (rows) => shapeReviewRows(supabase, rows),
    })
}
