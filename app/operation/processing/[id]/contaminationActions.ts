'use server'

// MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q25,Tim):加工单页上的交叉污染抽检 —— 记一次、记"这一班没抽"(理由)、更正一次。
//   判据全在库里(contamination_check_internal):批次必须是这一炉这条流的极片、外来物不超过样品、没抽要理由……这里只把输入框的字符串
//   变成参数(质量是克;空就是没给,交给库按名拒),再把拒绝说成人话。码:action.processing_aftercare(库里问同一个)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../../errorCodes'

export type CheckInput = {
    kind: 'sampled' | 'not_sampled'
    outputBatchId: string
    sampleG: string
    foreignG: string
    sampledAt: string
    method: string
    reason: string
}

function num(raw: string): number | undefined {
    const v = raw.trim()
    if (v === '') return undefined
    const n = Number(v)
    return Number.isFinite(n) ? n : NaN
}

function args(c: CheckInput) {
    const sampled = c.kind === 'sampled'
    return {
        p_kind: c.kind,
        p_output_batch_id: sampled && c.outputBatchId ? c.outputBatchId : undefined,
        p_sample_mass_g: sampled ? num(c.sampleG) : undefined,
        p_foreign_mass_g: sampled ? num(c.foreignG) : undefined,
        p_sampled_at: sampled && c.sampledAt ? c.sampledAt : undefined,
        p_method: c.method.trim() || undefined,
        p_not_sampled_reason: sampled ? undefined : c.reason.trim() || undefined,
    }
}

function refresh(runId: string) {
    revalidatePath(`/operation/processing/${runId}`)
    revalidatePath('/operation/contamination')
}

export async function recordContaminationCheck(runId: string, stream: string, c: CheckInput): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_contamination_check', { p_run_id: runId, p_stream_code: stream, ...args(c) })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId)
    return {}
}

export async function correctContaminationCheck(runId: string, checkId: number, c: CheckInput, why: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const a = args(c)
    const { error } = await supabase.rpc('correct_contamination_check', {
        p_check_id: checkId, p_kind: a.p_kind, p_output_batch_id: a.p_output_batch_id as string, p_sample_mass_g: a.p_sample_mass_g as number,
        p_foreign_mass_g: a.p_foreign_mass_g as number, p_sampled_at: a.p_sampled_at as string, p_method: a.p_method as string,
        p_not_sampled_reason: a.p_not_sampled_reason as string, p_reason: why,
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId)
    return {}
}
