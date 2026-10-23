// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):地磅单清单的统一导出 —— 服务端那一半。
// 页面只画最新 200 张并说出来;这里按页面【自己的】读取(../ticketsRows.ts)翻页取全,行只带导出格,以 JSON 交给表。
// 守卫与页面同一个判据(FN.weighbridge);超过 50,000 行按名拒绝。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { canEnter } from '@/lib/moduleAccess'
import { FN } from '@/lib/modules'
import { mustCount } from '@/lib/db-helpers'
import { exportRowsResponse, exportDenied } from '@/lib/export/serverRows'
import { ticketExports, ticketsCount, ticketsPage } from '../ticketsRows'

export async function GET() {
    if (!(await canEnter(FN.weighbridge.permission))) return exportDenied()
    const supabase = await createClient()
    const t = await getTranslations()
    const kgUnit = t('units.kg')
    return exportRowsResponse({
        label: 'weighbridge_ticket_weights',
        count: async () => mustCount(await ticketsCount(supabase), 'weighbridge_ticket_weights'),
        page: (from, to) => ticketsPage(supabase, from, to),
        shape: (rows) => rows.map((x) => ({ id: x.ticket_id, cells: {}, exports: ticketExports(x, t, kgUnit) })),
    })
}
