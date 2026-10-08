'use server'

// MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23–Q25;MES-5a Step 0 Q3–Q13,Tim):放电那一炉页面上的逐模组结果、通道分配与拆去隔离。
//   判据全在库里(discharge_result_internal / discharge_channel_internal / split_failed_modules_to_quarantine):这一批是这一炉的投料、
//   模组数先记、不超过模组数、失败必须说处置、拆的只能是"失败 · 隔离"的模组、库位必须是在用的隔离库位……
//   这里只把输入框的字符串变成参数(空就是没给,交给库按名拒),再把拒绝说成人话。
//   码:记结果与更正 action.confirm_capture;通道分配与拆分 action.processing_aftercare(拆分里那一炉另要 action.processing_commit)—— 库里问同一个。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeProcessingError } from '../../errorCodes'
import { PHOTO_BUCKET } from '@/app/operation/weighbridge/ticketFields'

export type ResultInput = {
    kind: 'inbound' | 'output'
    batchId: string
    moduleRef: string
    channelNo: string
    outletV: string
    startV: string
    verdict: 'pass' | 'fail'
    disposition: '' | 're_discharge' | 'quarantine'
    verdictAt: string
    durationMin: string
    energyWh: string
    deviceId: string
    photoPath: string
    notes: string
}

// 写不成数的不能送过去:JSON 里 NaN 就是 null,而 null 在这些参数上的意思是"没给" —— 一个打错的可选值会悄悄丢掉。
//   所以先找出第一个写不成数的字段,按库里那条码(DISCHARGE_VALUE_INVALID|<字段>)说出来;其余的判据仍全在库里。
function num(raw: string): number | undefined {
    const v = raw.trim()
    return v === '' ? undefined : Number(v)
}
function int(raw: string): number | undefined {
    const n = num(raw)
    return n === undefined || Number.isInteger(n) ? n : NaN
}
const opt = (s: string) => (s.trim() === '' ? undefined : s.trim())
/** 必填参数(函数签名里没有默认值):空 → 显式 null,让库按名拒(…_REQUIRED),而不是让 PostgREST 找不到函数或拿空串去解析日期 */
const req = (s: string) => (s.trim() === '' ? null : s.trim()) as string
async function unparsable(fields: [string, number | undefined][]): Promise<string | null> {
    const bad = fields.find(([, v]) => v !== undefined && !Number.isFinite(v))
    return bad ? await localizeProcessingError(bad[0] === 'outlet_voltage_v' ? 'DISCHARGE_VOLTAGE_INVALID' : `DISCHARGE_VALUE_INVALID|${bad[0]}`) : null
}
function parsed(r: ResultInput) {
    return {
        outlet: num(r.outletV), channel: int(r.channelNo), start: num(r.startV), duration: num(r.durationMin), energy: num(r.energyWh),
    }
}
async function badResult(r: ResultInput): Promise<string | null> {
    const p = parsed(r)
    return unparsable([['outlet_voltage_v', p.outlet], ['channel_no', p.channel], ['start_voltage_v', p.start],
                       ['duration_min', p.duration], ['energy_recovered_wh', p.energy]])
}

function refresh(runId: string, batches: { kind: string; id: string }[] = []) {
    revalidatePath(`/operation/processing/${runId}`)
    for (const b of batches) revalidatePath(b.kind === 'inbound' ? `/inbound/${b.id}/edit` : `/output/${b.id}/edit`)
}

export async function recordDischargeResult(runId: string, r: ResultInput): Promise<{ error?: string; verified?: boolean }> {
    const bad = await badResult(r)
    if (bad) return { error: bad }
    const p = parsed(r)
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_discharge_module_result', {
        p_run_id: runId, p_kind: r.kind, p_batch_id: r.batchId, p_module_ref: req(r.moduleRef),
        p_outlet_voltage_v: p.outlet as number, p_verdict: r.verdict, p_verdict_at: req(r.verdictAt),
        p_disposition: r.verdict === 'fail' ? opt(r.disposition) : undefined,
        p_channel_no: p.channel, p_start_voltage_v: p.start, p_duration_min: p.duration,
        p_energy_recovered_wh: p.energy, p_device_id: opt(r.deviceId), p_photo_path: opt(r.photoPath), p_notes: opt(r.notes),
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId, [{ kind: r.kind, id: r.batchId }])
    return { verified: !!(data as unknown as { verified?: boolean } | null)?.verified }
}

export async function correctDischargeResult(runId: string, resultId: number, r: ResultInput, why: string): Promise<{ error?: string }> {
    const bad = await badResult(r)
    if (bad) return { error: bad }
    const p = parsed(r)
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_discharge_module_result', {
        p_id: resultId, p_outlet_voltage_v: p.outlet as number, p_verdict: r.verdict, p_verdict_at: req(r.verdictAt),
        p_disposition: (r.verdict === 'fail' ? opt(r.disposition) : undefined) as string,
        p_channel_no: p.channel as number, p_start_voltage_v: p.start as number, p_duration_min: p.duration as number,
        p_energy_recovered_wh: p.energy as number, p_device_id: opt(r.deviceId) as string, p_photo_path: opt(r.photoPath) as string,
        p_notes: opt(r.notes) as string, p_reason: req(why),
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId, [{ kind: r.kind, id: r.batchId }])
    return {}
}

export async function assignDischargeChannel(runId: string, kind: 'inbound' | 'output', batchId: string, channelNo: string, moduleRef: string): Promise<{ error?: string }> {
    const bad = await unparsable([['channel_no', int(channelNo)]])
    if (bad) return { error: bad }
    const supabase = await createClient()
    const { error } = await supabase.rpc('assign_discharge_channel', {
        p_run_id: runId, p_kind: kind, p_batch_id: batchId, p_channel_no: int(channelNo) as number, p_module_ref: req(moduleRef),
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId)
    return {}
}

export async function correctDischargeChannel(runId: string, assignmentId: number, channelNo: string, moduleRef: string, withdraw: boolean, why: string): Promise<{ error?: string }> {
    const bad = withdraw ? null : await unparsable([['channel_no', int(channelNo)]])
    if (bad) return { error: bad }
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_discharge_channel', {
        p_id: assignmentId, p_channel_no: int(channelNo) as number, p_module_ref: req(moduleRef), p_withdraw: withdraw, p_reason: req(why),
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    refresh(runId)
    return {}
}

export type SplitInput = {
    kind: 'inbound' | 'output'
    batchId: string
    modules: string[]
    processDate: string
    startedAt: string
    endedAt: string
    shift: string
    locationId: string
    weightKg: string
    notes: string
}

export async function splitFailedModules(runId: string, s: SplitInput): Promise<{ error?: string; splitRunId?: string }> {
    const w = num(s.weightKg)
    if (w !== undefined && !Number.isFinite(w)) return { error: await localizeProcessingError('OUTPUT_WEIGHING_REQUIRED|1') }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('split_failed_modules_to_quarantine', {
        p_discharge_run_id: runId, p_kind: s.kind, p_batch_id: s.batchId, p_module_refs: s.modules,
        p_process_date: req(s.processDate), p_started_at: req(s.startedAt), p_ended_at: req(s.endedAt), p_shift_code: req(s.shift),
        p_location_id: req(s.locationId), p_weight_kg: num(s.weightKg), p_notes: opt(s.notes),
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    const out = data as unknown as { split_run_id?: string; batch_id?: string } | null
    refresh(runId, [{ kind: s.kind, id: s.batchId }, ...(out?.batch_id ? [{ kind: 'output', id: out.batch_id }] : [])])
    revalidatePath('/operation/processing')
    return { splitRunId: out?.split_run_id }
}

/** 一张放电屏幕照片的短时链接(私有桶 capture-photos;读要收货或物流查看码 —— 桶的策略判,这里不重算)。 */
export async function dischargePhotoUrl(filePath: string): Promise<{ url?: string; error?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.storage.from(PHOTO_BUCKET).createSignedUrl(filePath, 60)
    if (error || !data?.signedUrl) return { error: (await getTranslations())('discharge.photoOpenError') }
    return { url: data.signedUrl }
}
