// MES-4b(2026-10-07):把 contamination_check_rows 的一行变成清单的一行 —— 产出批页与 /operation/contamination 共用一份。
//   单号只在读者持 module.processing.view 时成为链接(加工单页的门就是它)。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'
import { formatDate, formatDateTime } from '@/lib/dates'
import type { CheckListRow } from './ContaminationChecksList'

type Raw = {
    id: number; run_id: string; run_code: string; process_date: string; shift_code: string | null; stream_code: string; kind: string
    output_batch_code: string | null; rate_pct: number | null; warning_pct_at: number | null; above_warning: boolean | null
    sampled_at: string | null; not_sampled_reason: string | null; corrects_id: number | null; correction_reason: string | null
}
export const CHECK_ROW_COLUMNS = 'id, run_id, run_code, process_date, shift_code, stream_code, kind, output_batch_code, rate_pct, warning_pct_at, above_warning, sampled_at, not_sampled_reason, corrects_id, correction_reason'

export async function labelsFor(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>, locale: string,
): Promise<{ stream: (c: string) => string; shift: (c: string | null) => string }> {
    const [sRes, shRes] = await Promise.all([
        supabase.from('contamination_streams').select('code, name_en, name_zh'),
        supabase.from('shifts').select('code, name_en, name_zh'),
    ])
    const nm = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)
    const streams = new Map((mustRows(sRes, 'contamination_streams') as { code: string; name_en: string; name_zh: string }[]).map((r) => [r.code, nm(r)]))
    const shifts = new Map((mustRows(shRes, 'shifts') as { code: string; name_en: string; name_zh: string }[]).map((r) => [r.code, nm(r)]))
    return { stream: (c) => streams.get(c) ?? c, shift: (c) => (c ? shifts.get(c) ?? c : '—') }
}

export function toCheckListRows(raw: unknown[], labels: { stream: (c: string) => string; shift: (c: string | null) => string },
                                locale: string, canOpenRuns: boolean): CheckListRow[] {
    return (raw as Raw[]).map((c) => ({
        id: c.id, runCode: c.run_code, runHref: canOpenRuns ? `/operation/processing/${c.run_id}` : null,
        date: formatDate(c.process_date, locale), shift: labels.shift(c.shift_code), stream: labels.stream(c.stream_code),
        kind: c.kind === 'not_sampled' ? 'not_sampled' : 'sampled', batchCode: c.output_batch_code,
        ratePct: c.rate_pct === null ? null : Number(c.rate_pct), warningPctAt: c.warning_pct_at === null ? null : Number(c.warning_pct_at),
        above: c.above_warning, sampledAt: c.sampled_at ? formatDateTime(c.sampled_at, locale) : null,
        notSampledReason: c.not_sampled_reason, corrected: c.corrects_id !== null, correctionReason: c.correction_reason,
    }))
}
