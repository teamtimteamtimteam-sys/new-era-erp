// TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2):流水台账的统一导出 —— 服务端那一半。
// 页面只画最新 1,000 条并说出来;这里按页面【自己的】筛选(../ledgerQuery.ts)取全:两侧(进料批 / 产出批)各自翻页取全、
// 合并、同一个次序(上限 50,000)。守卫与页面同一个判据(MOD.inventory)。
// 行在合并之后才有次序,所以 count 与 page 读的是同一份合并结果(先取全,再按 from..to 切给 exportRowsResponse)。
import type { NextRequest } from 'next/server'
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { canEnter } from '@/lib/moduleAccess'
import { MOD } from '@/lib/modules'
import { exportRowsResponse, exportDenied, EXPORT_CAP } from '@/lib/export/serverRows'
import { fetchLedgerAll, ledgerCount, parseLedgerParams } from '../ledgerQuery'
import { shapeLedgerRows } from '../ledgerRows'

export async function GET(req: NextRequest) {
    if (!(await canEnter(MOD.inventory.permission))) return exportDenied()
    const supabase = await createClient()
    const p = parseLedgerParams(Object.fromEntries(req.nextUrl.searchParams))
    const t = await getTranslations()
    let all: Awaited<ReturnType<typeof fetchLedgerAll>> | null = null
    return exportRowsResponse({
        label: 'inventory_movements',
        count: () => ledgerCount(supabase, p),
        page: async (from, to) => {
            // 先数过了(count 超过 50,000 时 exportRowsResponse 不会走到这里)
            all ??= await fetchLedgerAll(supabase, p)
            return { data: all.slice(from, Math.min(to + 1, EXPORT_CAP + 1)), error: null }
        },
        shape: (rows) => shapeLedgerRows(rows, t),
    })
}
