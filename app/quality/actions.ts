'use server'

// MES-6a-1(2026-10-09,MES-6a Step 0 Q7–Q23,Tim):样品与化验争议的动作 —— 全部转达给数据库,页面不自己判断。
//   拒绝按名翻译(localizeQualityError)。日期与时刻不在这里补默认值:取样日与保管时刻都由人说,空就由服务端按名拒。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeQualityError } from './qualityErrorCodes'

export type QualityState = { error?: string }

function revalidateBatch(kind: 'inbound' | 'output' | null, batchId: string | null) {
    if (kind && batchId) revalidatePath(`/${kind}/${batchId}/edit`)
}

export async function recordSample(input: {
    kind: string; takenOn: string; inboundBatchId: string | null; outputBatchId: string | null; massG: string
    salesOrderId: string | null; contaminationCheckId: string | null; storageLocationId: string | null; notes: string
}): Promise<QualityState> {
    const supabase = await createClient()
    const mass = input.massG.trim() === '' ? undefined : Number(input.massG)
    const { data, error } = await supabase.rpc('record_sample', {
        p_kind: input.kind,
        p_taken_on: input.takenOn,
        p_inbound_batch_id: input.inboundBatchId ?? undefined,
        p_output_batch_id: input.outputBatchId ?? undefined,
        p_mass_g: mass,
        p_sales_order_id: input.salesOrderId ?? undefined,
        p_contamination_check_id: input.contaminationCheckId ? Number(input.contaminationCheckId) : undefined,
        p_storage_location_id: input.storageLocationId ?? undefined,
        p_notes: input.notes.trim() || undefined,
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidatePath('/quality/samples')
    revalidateBatch(input.inboundBatchId ? 'inbound' : 'output', input.inboundBatchId ?? input.outputBatchId)
    redirect(`/quality/samples/${(data as { sample_id: string }).sample_id}`)
}

export async function recordSampleEvent(sampleId: string, input: {
    eventKind: string; occurredAt: string; laboratoryCode: string | null; labReference: string; storageLocationId: string | null
    reason: string; notes: string
}): Promise<QualityState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_sample_event', {
        p_sample_id: sampleId,
        p_event_kind: input.eventKind,
        p_occurred_at: input.occurredAt,
        p_laboratory_code: input.laboratoryCode ?? undefined,
        p_lab_reference: input.labReference.trim() || undefined,
        p_storage_location_id: input.storageLocationId ?? undefined,
        p_reason: input.reason.trim() || undefined,
        p_notes: input.notes.trim() || undefined,
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidatePath(`/quality/samples/${sampleId}`)
    revalidatePath('/quality/samples')
    return {}
}

export async function setQualitySettings(days: string): Promise<QualityState> {
    const supabase = await createClient()
    const raw = days.trim()
    if (raw !== '' && !/^\d+$/.test(raw)) return { error: await localizeQualityError(`QUALITY_RETENTION_DAYS_INVALID|${raw}`) }
    // 空 = 清空(回到 Not yet set)—— 生成的类型把它写成 number,而这一格本来就可空(set_quality_settings 收 NULL)
    const { error } = await supabase.rpc('set_quality_settings', {
        p_internal_retention_days: raw === '' ? (null as unknown as number) : Number(raw),
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidatePath('/quality/samples')
    revalidatePath('/settings/pending-values')
    return {}
}

export async function openDispute(input: {
    ourAssayId: string; counterpartyAssayId: string; reason: string; salesOrderId: string | null
}): Promise<QualityState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('open_assay_dispute', {
        p_our_assay_id: input.ourAssayId,
        p_counterparty_assay_id: input.counterpartyAssayId,
        p_reason: input.reason,
        p_sales_order_id: input.salesOrderId ?? undefined,
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidatePath('/quality/disputes')
    redirect(`/quality/disputes/${(data as { dispute_id: string }).dispute_id}`)
}

function revalidateDispute(id: string) {
    revalidatePath(`/quality/disputes/${id}`)
    revalidatePath('/quality/disputes')
}

export async function recordDisputeUmpire(id: string, umpireSampleId: string | null, umpireAssayId: string | null): Promise<QualityState> {
    const supabase = await createClient()
    // 两样都可空(至少给一样 —— 服务端按名拒 ASSAY_DISPUTE_UMPIRE_EMPTY);生成的类型把它们写成必填的 string
    const { error } = await supabase.rpc('record_dispute_umpire', {
        p_dispute_id: id,
        p_umpire_sample_id: umpireSampleId as string,
        p_umpire_assay_id: umpireAssayId as string,
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidateDispute(id)
    return {}
}

export async function withdrawDispute(id: string, reason: string): Promise<QualityState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('withdraw_assay_dispute', { p_dispute_id: id, p_reason: reason })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidateDispute(id)
    return {}
}

export async function resolveDispute(id: string, governingAssayId: string, note: string): Promise<QualityState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('resolve_assay_dispute', { p_dispute_id: id, p_governing_assay_id: governingAssayId, p_note: note })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidateDispute(id)
    return {}
}

export async function linkDisputeFee(id: string, expenseId: string): Promise<QualityState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('link_dispute_fee', { p_dispute_id: id, p_expense_id: expenseId })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidateDispute(id)
    return {}
}
