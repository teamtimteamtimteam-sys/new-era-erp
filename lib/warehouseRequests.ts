// lib/warehouseRequests.ts
// ★ APR-7(Tim 2026-09-25):一张在等 CFO 的仓库申请(注销 · 回滚 · 证书作废)碰到了哪些东西 ——
//   给三张表(进料 / 产出 / 加工单)与证书面板画"按不动、说出是哪一张在等"。
//   ☞ 判据在库里(warehouse_request_touches,提交时按名拒 WAREHOUSE_REQUEST_OPEN);这里只是从
//     warehouse_requests_visible() 的 snapshot 把同一组东西【按编号】摊开,好让屏幕在按之前就说出来。
//     读不到(不持 module.inventory.view)时是空表 —— 那时按钮照常,由库按名拒,不画一句假的"没有在等"。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'

type Snapshot = {
    batch_code?: string
    run_code?: string
    cod_code?: string
    outputs?: string[]
    inputs?: string[]
    cods_voided?: string[]
}

/** 编号(批号 / 单号 / 证书号)→ 碰到它的那一张在等的申请的 label */
export async function openWarehouseRequestsByCode(supabase: SupabaseClient<Database>): Promise<Map<string, string>> {
    const rows = mustRows(await supabase.rpc('warehouse_requests_visible', { p_recent: 0 })) as {
        status: string; label: string; snapshot: Snapshot | null
    }[]
    const byCode = new Map<string, string>()
    for (const r of rows) {
        if (r.status !== 'submitted') continue
        const s = r.snapshot ?? {}
        const codes = [s.batch_code, s.run_code, s.cod_code, ...(s.outputs ?? []), ...(s.inputs ?? []), ...(s.cods_voided ?? [])]
        for (const c of codes) if (c && !byCode.has(c)) byCode.set(c, r.label)
    }
    return byCode
}
