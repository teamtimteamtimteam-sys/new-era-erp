// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · 2026-10-23 TABLE-EXPORT-2b Q1):确认队列上「等确认的草稿」那张表的统一导出 —— 服务端那一半。
// 页面画最老的 200 张;这里按页面【自己的】读取(../../captureRows.ts)翻页取全,行只带导出格,以 JSON 交给表。守卫与页面同一个判据(FN.capture)。
// 两张表各一条路由(从前是一条 ?table= 的路由 —— 不带参数时答 400,一条要靠隐藏参数才对的路由站不住,smoke 把它点了出来)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { deviceRefs, draftExports, pendingCount, pendingPage, parsePendingSort } from '../../captureRows'

export async function GET(request: NextRequest) {
    if (!(await canEnter(FN.capture.permission))) return exportDenied()
    // TABLE-FEATURES-1 Q9:与页面同一份排序参数
    const sort = parsePendingSort(Object.fromEntries(request.nextUrl.searchParams))
    const supabase = await createClient()
    const kgUnit = (await getTranslations())('units.kg')
    return exportRowsResponse({
        label: 'capture_drafts',
        count: async () => mustCount(await pendingCount(supabase), 'capture_drafts'),
        page: (from, to) => pendingPage(supabase, sort, from, to),
        shape: async (rows) => {
            const devs = await deviceRefs(supabase)
            return rows.map((d) => ({ id: d.id, cells: {}, exports: draftExports(d, d.device_id ? devs.get(d.device_id) : null, kgUnit) }))
        },
    })
}
