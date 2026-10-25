// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):数据收件箱的统一导出 —— 服务端那一半。
// 页面一页 200 行、可以翻页;导出不论在哪一页,都按页面【自己的】读取与筛选(?status=,../inboxRows.ts)翻页取全(上限 50,000)。
// 行只带导出格,以 JSON 交给表。守卫与页面同一个判据(FN.captureInbox)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { inboxCount, inboxExports, inboxLabels, inboxPage, inboxStatus, parseInboxSort } from '../inboxRows'

export async function GET(req: NextRequest) {
    if (!(await canEnter(FN.captureInbox.permission))) return exportDenied()
    const supabase = await createClient()
    const status = inboxStatus(req.nextUrl.searchParams.get('status'))
    // TABLE-FEATURES-1 Q9:与页面同一份排序参数
    const sort = parseInboxSort(Object.fromEntries(req.nextUrl.searchParams))
    const t = await getTranslations()
    const locale = await getLocale()
    return exportRowsResponse({
        label: 'ingest_inbox',
        count: async () => mustCount(await inboxCount(supabase, status), 'ingest_inbox'),
        page: (from, to) => inboxPage(supabase, status, sort, from, to),
        shape: async (rows) => {
            const lb = await inboxLabels(supabase, locale)
            return rows.map((r) => ({ id: String(r.id), cells: {}, exports: inboxExports(r, lb, t) }))
        },
    })
}
