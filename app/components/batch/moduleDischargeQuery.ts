// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4 · Q13,Tim):批次页上的模组数与逐模组放电结论 —— 进料批与产出批共用的读取。
//   【读的都是带门的读法】discharge_status_by_batch · discharge_module_rows · discharge_module_splits(加工 / 进料 / 产出查看码任一)。
//   放电那一炉的单号是视图借过来的显示标签;能不能点进去问的是加工查看码(进不去的不给链接,单号照样写)。
//   【核实与否不在这里算】进度与"此刻是否开着已放电并核实"都是视图给的;这一批不在视图里 = 没有模组数、没有结果、没放过电 → null。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'
import { formatDateTime } from '@/lib/dates'

export type ModuleSummaryRow = {
    moduleRef: string; verdict: 'pass' | 'fail'; disposition: 're_discharge' | 'quarantine' | null
    outletV: number; verdictAt: string; runId: string; runCode: string; attempts: number; splitOut: boolean; contradicts: boolean | null
}
export type BatchDischargeData = {
    status: {
        moduleCount: number | null; passed: number; failedRedischarge: number; failedQuarantine: number; splitOut: number
        contradictions: number; verified: boolean; latestRunId: string | null; latestRunCode: string | null
    } | null
    modules: ModuleSummaryRow[]
    /** 这一批是拆去隔离拆出来的:从哪一炉、哪几个模组 */
    splitFrom: { splitRunId: string; splitRunCode: string | null; modules: string[] } | null
}

export async function loadBatchDischarge(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>, batchId: string, locale: string,
    /** 持加工查看码:拆分那一炉的单号从 processing_runs_masked 读(读不到的人不去读,不把零行说成没有) */
    canOpenRuns: boolean,
): Promise<BatchDischargeData> {
    const [statusRes, rowsRes, splitRes] = await Promise.all([
        supabase.from('discharge_status_by_batch')
            .select('module_count, passed, failed_redischarge, failed_quarantine, split_out, contradictions, currently_verified, latest_run_id, latest_run_code')
            .eq('batch_id', batchId),
        supabase.from('discharge_module_rows')
            .select('module_ref, verdict, disposition, outlet_voltage_v, verdict_at, run_id, run_code, is_current, is_latest, split_out, contradicts_pass_voltage')
            .eq('batch_id', batchId).order('id'),
        supabase.from('discharge_module_splits').select('split_run_id, module_ref').eq('new_output_batch_id', batchId).order('id'),
    ])
    const s = (mustRows(statusRes, 'discharge_status_by_batch') as unknown as {
        module_count: number | null; passed: number; failed_redischarge: number; failed_quarantine: number; split_out: number
        contradictions: number; currently_verified: boolean; latest_run_id: string | null; latest_run_code: string | null
    }[])[0]
    const rows = mustRows(rowsRes, 'discharge_module_rows') as unknown as {
        module_ref: string; verdict: string; disposition: string | null; outlet_voltage_v: number; verdict_at: string
        run_id: string; run_code: string; is_current: boolean; is_latest: boolean; split_out: boolean; contradicts_pass_voltage: boolean | null
    }[]
    const splits = mustRows(splitRes, 'discharge_module_splits') as unknown as { split_run_id: string; module_ref: string }[]
    const splitRunCode = canOpenRuns && splits.length > 0
        ? ((mustRows(await supabase.from('processing_runs_masked').select('code').eq('id', splits[0].split_run_id), 'processing_runs_masked') as
            unknown as { code: string }[])[0]?.code ?? null)
        : null
    const attempts = new Map<string, number>()
    for (const r of rows) if (r.is_current) attempts.set(r.module_ref, (attempts.get(r.module_ref) ?? 0) + 1)
    return {
        status: s ? {
            moduleCount: s.module_count, passed: Number(s.passed), failedRedischarge: Number(s.failed_redischarge),
            failedQuarantine: Number(s.failed_quarantine), splitOut: Number(s.split_out), contradictions: Number(s.contradictions),
            verified: s.currently_verified, latestRunId: s.latest_run_id, latestRunCode: s.latest_run_code,
        } : null,
        modules: rows.filter((r) => r.is_latest).map((r) => ({
            moduleRef: r.module_ref, verdict: r.verdict === 'fail' ? 'fail' as const : 'pass' as const,
            disposition: r.disposition === 'quarantine' ? 'quarantine' as const : r.disposition === 're_discharge' ? 're_discharge' as const : null,
            outletV: Number(r.outlet_voltage_v), verdictAt: formatDateTime(r.verdict_at, locale), runId: r.run_id, runCode: r.run_code,
            attempts: attempts.get(r.module_ref) ?? 1, splitOut: r.split_out, contradicts: r.contradicts_pass_voltage,
        })).sort((a, b) => a.moduleRef.localeCompare(b.moduleRef)),
        splitFrom: splits.length > 0 ? { splitRunId: splits[0].split_run_id, splitRunCode, modules: splits.map((x) => x.module_ref).sort() } : null,
    }
}
