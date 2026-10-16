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

// ══ MES-7b-2(2026-10-16,MES-7b Step 0 Q13–Q16,Tim):巡检清单 · 巡检 · 发现 · 任务 · 环境监测 ══════════════════════════════════
//   同样全部转达给数据库;巡检时刻与采样日由人说(空就由服务端按名拒),这里不补默认值。超标会不会开事故、要不要答 NEA,由库判、按名拒。

function revalidateRun(runId: string) {
    revalidatePath(`/safety/inspections/${runId}`)
    revalidatePath('/safety/inspections')
}

export async function saveInspectionTemplate(templateId: string | null, input: {
    code: string; name: string; area: string; frequencyDays: string; isActive: boolean; notes: string; items: string[]
}): Promise<SafetyState> {
    const supabase = await createClient()
    const freq = input.frequencyDays.trim() === '' ? null : Number(input.frequencyDays)
    if (freq !== null && (!Number.isInteger(freq) || freq < 1)) return { error: await localizeSafetyError('INSPECTION_TEMPLATE_FREQUENCY_INVALID') }
    const { data, error } = await supabase.rpc('save_inspection_template', {
        p_template_id: templateId as string,
        p_code: input.code,
        p_name: input.name,
        p_area: input.area,
        p_items: input.items,
        p_frequency_days: freq as number,
        p_is_active: input.isActive,
        p_notes: blank(input.notes),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    const id = (data as { template_id: string }).template_id
    revalidatePath('/safety/inspections')
    revalidatePath(`/safety/inspections/templates/${id}`)
    revalidatePath('/settings/pending-values')
    if (!templateId) redirect(`/safety/inspections/templates/${id}`)
    return {}
}

export async function recordInspectionRun(input: {
    templateId: string; inspectedAt: string; inspectorEmployeeId: string; locationId: string; equipmentId: string; notes: string
    results: { position: number; result: string; note: string }[]
    findings: { position: number; correctiveAction: string; ownerEmployeeId: string; dueDate: string }[]
    correctsRunId: string | null; correctionReason: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('record_inspection_run', {
        p_template_id: input.templateId,
        p_inspected_at: input.inspectedAt,
        p_inspector_employee_id: input.inspectorEmployeeId,
        p_results: input.results.map((r) => ({ position: r.position, result: r.result, note: blank(r.note) ?? null })),
        p_location_id: blank(input.locationId),
        p_equipment_id: blank(input.equipmentId),
        p_notes: blank(input.notes),
        p_findings: input.findings.map((f) => ({ position: f.position, corrective_action: f.correctiveAction,
                                                 owner_employee_id: blank(f.ownerEmployeeId) ?? null, due_date: blank(f.dueDate) ?? null })),
        p_corrects_run_id: input.correctsRunId ?? undefined,
        p_correction_reason: blank(input.correctionReason),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    const runId = (data as { run_id: string }).run_id
    revalidatePath('/safety/inspections')
    revalidatePath(`/safety/inspections/templates/${input.templateId}`)
    if (input.correctsRunId) revalidatePath(`/safety/inspections/${input.correctsRunId}`)
    redirect(`/safety/inspections/${runId}`)
}

export async function recordInspectionFinding(runId: string, input: {
    position: number; correctiveAction: string; ownerEmployeeId: string; dueDate: string
}): Promise<SafetyState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_inspection_finding', {
        p_run_id: runId,
        p_position: input.position,
        p_corrective_action: input.correctiveAction,
        p_owner_employee_id: input.ownerEmployeeId,
        p_due_date: blank(input.dueDate),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateRun(runId)
    return {}
}

export async function closeInspectionFinding(runId: string, findingId: string, whatWasDone: string): Promise<SafetyState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_inspection_finding', { p_finding_id: findingId, p_what_was_done: whatWasDone })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateRun(runId)
    return {}
}

/** Q14:"建一张任务" —— 给按下它的人建一张私人任务,发现指着它;关掉那张任务不关闭发现。 */
export async function raiseInspectionFindingTask(runId: string, findingId: string): Promise<SafetyState & { taskCode?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('raise_inspection_finding_task', { p_finding_id: findingId })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidateRun(runId)
    revalidatePath('/tools/tasks')
    return { taskCode: (data as { task_code: string }).task_code }
}

export async function recordEnvironmentalResult(input: {
    parameterCode: string; samplePoint: string; sampledOn: string; laboratoryCode: string; reportReference: string; value: string
    neaReportable: boolean | null; immediateAction: string; correctsResultId: string | null; correctionReason: string
}): Promise<SafetyState & { incidentId?: string | null }> {
    const supabase = await createClient()
    const value = input.value.trim() === '' ? null : Number(input.value)
    if (value !== null && !Number.isFinite(value)) return { error: await localizeSafetyError('ENV_VALUE_REQUIRED') }
    const { data, error } = await supabase.rpc('record_environmental_result', {
        p_parameter_code: input.parameterCode,
        p_sample_point: input.samplePoint,
        p_sampled_on: input.sampledOn,
        p_laboratory_code: input.laboratoryCode,
        p_report_reference: input.reportReference,
        p_value: value as number,
        // 【超标时要不要通报没有默认】没回答原样送空,由服务端按名拒 —— 不在这里替人回答
        p_nea_reportable: input.neaReportable ?? undefined,
        p_immediate_action: blank(input.immediateAction),
        p_corrects_result_id: input.correctsResultId ?? undefined,
        p_correction_reason: blank(input.correctionReason),
    })
    if (error) return { error: await localizeSafetyError(error.message) }
    revalidatePath('/safety/environment')
    const incidentId = (data as { incident_id: string | null }).incident_id
    if (incidentId) revalidatePath('/safety/incidents')
    return { incidentId }
}
