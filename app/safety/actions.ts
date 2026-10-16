'use server'

// MES-7b-1(2026-10-16,MES-7b Step 0 Q3–Q12,Tim):事故登记簿的动作 —— 全部转达给数据库,页面不自己判断。
//   拒绝按名翻译(localizeSafetyError;开来源 incident 的不合格报告走质量那一边的 localizeQualityError)。
//   时刻不在这里补默认值:发生时刻、通报时刻、交报告的时刻都由人说,空就由服务端按名拒(AGENTS.md:世界那一侧的日子不给默认)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeSafetyError } from './safetyErrorCodes'
import { localizeQualityError } from '@/app/quality/qualityErrorCodes'

export type SafetyState = { error?: string }

const blank = (v: string | null | undefined) => (v == null || v.trim() === '' ? undefined : v.trim())

function revalidateIncident(id: string) {
    revalidatePath(`/safety/incidents/${id}`)
    revalidatePath('/safety/incidents')
}

export async function recordIncident(input: {
    kindCode: string; occurredAt: string; whatHappened: string; immediateAction: string; neaReportable: boolean | null
    responsibleEmployeeId: string; responsibleName: string; locationId: string; equipmentId: string; durationMin: string
    downtimeId: string; runEventId: string; injuredEmployeeId: string; injuredPersonName: string; injuryNature: string
    injuryTreatment: string; daysLost: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_incident', {
        p_kind_code: input.kindCode,
        p_occurred_at: input.occurredAt,
        p_what_happened: input.whatHappened,
        p_immediate_action: input.immediateAction,
        // 【要不要通报没有默认】(Q10)一个没回答的"是 / 否"原样送空,由服务端按名拒 —— 不在这里替人回答"否"
        p_nea_reportable: input.neaReportable as boolean,
        p_responsible_employee_id: blank(input.responsibleEmployeeId),
        p_responsible_name: blank(input.responsibleName),
        p_location_id: blank(input.locationId),
        p_equipment_id: blank(input.equipmentId),
        p_duration_min: blank(input.durationMin) === undefined ? undefined : Number(input.durationMin),
        p_downtime_id: blank(input.downtimeId),
        p_run_event_id: blank(input.runEventId) === undefined ? undefined : Number(input.runEventId),
        p_injured_employee_id: blank(input.injuredEmployeeId),
        p_injured_person_name: blank(input.injuredPersonName),
        p_injury_nature: blank(input.injuryNature),
        p_injury_treatment: blank(input.injuryTreatment),
        p_days_lost: blank(input.daysLost) === undefined ? undefined : Number(input.daysLost),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidatePath('/safety/incidents')
    redirect(`/safety/incidents/${(data as { incident_id: string }).incident_id}`)
}

export async function recordIncidentUpdate(incidentId: string, input: {
    kind: 'nea_notified' | 'report_submitted' | 'closed' | 'correction'
    occurredAt?: string; reference?: string; field?: string; newValue?: string; reason?: string; summary?: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_incident_update', {
        p_incident_id: incidentId,
        p_kind: input.kind,
        p_occurred_at: blank(input.occurredAt),
        p_reference: blank(input.reference),
        p_field: blank(input.field),
        p_new_value: blank(input.newValue),
        p_reason: blank(input.reason),
        p_summary: blank(input.summary),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateIncident(incidentId)
    return {}
}

export async function linkIncidentBatch(incidentId: string, input: {
    basis: 'location' | 'machine_run' | 'picked'; batchKind: 'inbound' | 'output'; batchId: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('link_incident_batch', {
        p_incident_id: incidentId,
        p_basis: input.basis,
        p_inbound_batch_id: input.batchKind === 'inbound' ? input.batchId : undefined,
        p_output_batch_id: input.batchKind === 'output' ? input.batchId : undefined,
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateIncident(incidentId)
    revalidatePath(`/${input.batchKind}/${input.batchId}/edit`)
    return {}
}

export async function unlinkIncidentBatch(incidentId: string, linkId: number, reason: string): Promise<SafetyState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('unlink_incident_batch', { p_link_id: linkId, p_reason: reason })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateIncident(incidentId)
    return {}
}

export async function setSafetySettings(input: { days: string; confirmed: boolean; source: string }): Promise<SafetyState> {
    const supabase = await createClient()
    const days = input.days.trim() === '' ? null : Number(input.days)
    if (days !== null && (!Number.isInteger(days) || days < 1)) return { error: await localizeSafetyError('SAFETY_REPORT_DAYS_INVALID') }
    const { error } = await supabase.rpc('set_safety_settings', {
        p_nea_report_working_days: days as number,
        p_confirmed: input.confirmed,
        p_source: blank(input.source),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidatePath('/safety/incidents')
    revalidatePath('/settings/pending-values')
    return {}
}

/** Q8:事故页上,持 module.quality.edit 的人对一批【链在这件事故上】的货开一张来源 incident 的不合格报告 —— 既有的质量暂扣照常生效。 */
export async function openIncidentNcr(incidentId: string, input: {
    batchKind: 'inbound' | 'output'; batchId: string; description: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('open_ncr', {
        p_source: 'incident',
        p_description: input.description,
        p_inbound_batch_id: input.batchKind === 'inbound' ? input.batchId : undefined,
        p_output_batch_id: input.batchKind === 'output' ? input.batchId : undefined,
        p_incident_id: incidentId,
    })
    if (error) return { error: await localizeQualityError(error.message) }
    revalidateIncident(incidentId)
    revalidatePath('/quality/ncr')
    revalidatePath(`/${input.batchKind}/${input.batchId}/edit`)
    redirect(`/quality/ncr/${(data as { ncr_id: string }).ncr_id}`)
}
