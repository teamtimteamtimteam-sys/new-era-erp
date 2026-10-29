import 'server-only'

// app/operation/handovers/shiftRuns.ts
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-4(Tim 2026-10-29 第 7 条 · 2026-10-30 Q5)· 一次交接班的班上处理了什么
// ════════════════════════════════════════════════════════════════════════════
// 【怎么配】一张加工单的【班次 + 加工日】= 这次交接班的【班次 + 交接日】(Tim Q5)。
//   不按时刻窗口配:shifts 的起止时刻今天两个班都是空的(db/tables/shifts.sql 的种子,Tim 没给过);
//   而加工日是开单的人写下的那一天,库里已经要求它落在开始与结束的新加坡日期之间(assert_run_header)——
//   于是一个跨午夜的夜班,它的单归到单上写的那一天。
// 【MES-4a 之前的单】没有班次,配不上任何一次交接班 —— 不藏起来:同一天这样的单有几张,说一个具名的数。
// 【只读】这一页与新建交接班那一屏共用这一份读取(详情页直接调,表单经 actions.ts 的 shiftRunsFor 调),
//   于是两处列出来的单不可能不一样。读 processing_runs_masked(遮蔽伴生视图;这里用到的列都不遮),软删除的不算。
import { mustRows } from '@/lib/db-helpers'
import { formatDateTime } from '@/lib/dates'
import type { createClient } from '@/lib/supabase/server'

export type ShiftRun = {
    id: string
    code: string
    operation: string
    startedAt: string | null
    endedAt: string | null
    startedAtRaw: string | null
    endedAtRaw: string | null
    input: number | null
    output: number | null
    loss: number | null
    status: string
}
export type ShiftRuns = { runs: ShiftRun[]; unattributed: number }

export async function readShiftRuns(
    supabase: Awaited<ReturnType<typeof createClient>>, shiftCode: string, date: string, locale: string,
): Promise<ShiftRuns> {
    const [runRes, noShiftRes, opRes] = await Promise.all([
        supabase.from('processing_runs_masked')
            .select('id, code, operation_type_code, started_at, ended_at, total_input, total_output, loss_qty, status')
            .eq('shift_code', shiftCode).eq('process_date', date).is('deleted_at', null)
            .order('started_at', { ascending: true }).order('code'),
        supabase.from('processing_runs_masked').select('id', { count: 'exact', head: true })
            .is('shift_code', null).eq('process_date', date).is('deleted_at', null),
        supabase.from('operation_types').select('code, name_en, name_zh'),
    ])
    if (noShiftRes.error) throw new Error(`查询失败(processing_runs_masked 计数): ${noShiftRes.error.message}`)
    const ops = mustRows(opRes, 'operation_types') as { code: string; name_en: string | null; name_zh: string | null }[]
    const opName = (code: string | null) => {
        if (!code) return '—'
        const o = ops.find((x) => x.code === code)
        return (o ? (locale === 'zh' ? o.name_zh : o.name_en) : null) ?? code
    }
    const runs = (mustRows(runRes, 'processing_runs_masked') as {
        id: string; code: string; operation_type_code: string | null; started_at: string | null; ended_at: string | null
        total_input: number | null; total_output: number | null; loss_qty: number | null; status: string
    }[]).map((r) => ({
        id: r.id,
        code: r.code,
        operation: opName(r.operation_type_code),
        startedAt: r.started_at ? formatDateTime(r.started_at, locale) : null,
        endedAt: r.ended_at ? formatDateTime(r.ended_at, locale) : null,
        startedAtRaw: r.started_at,
        endedAtRaw: r.ended_at,
        input: r.total_input,
        output: r.total_output,
        loss: r.loss_qty,
        status: r.status,
    }))
    return { runs, unattributed: noShiftRes.count ?? 0 }
}
