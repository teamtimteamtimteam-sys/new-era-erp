'use server'

// ESG-2(Tim 2026-10-31 Q1–Q15):ESG 的设定与登记簿的动作 —— 全部转达给数据库(esg_set_grid_factor · esg_set_standard_hours ·
//   required_training_save / _retire · company_policy_record · whistleblowing_report_record_outside / _update),页面不自己判断。
//   门都由库判(action.manage_esg / 举报的读码);这里只把拒绝说成人话(localizeEsgError)。日期不在这里补默认值(AGENTS.md)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeEsgError } from './esgErrorCodes'

export type EsgState = { error?: string; id?: string }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const blank = (v: string | null | undefined) => (v == null || v.trim() === '' ? null : v.trim())
/** 一个文本框里的数:空 → null;认不出 → NaN(交给库按名拒,不在这里编一个) */
const numOrNull = (v: string) => (v.trim() === '' ? null : Number(v.trim()))

export async function setGridFactor(input: { year: string; value: string; source: string; reason: string }): Promise<EsgState> {
    const year = Number(input.year)
    const value = numOrNull(input.value)
    if (!Number.isInteger(year)) return { error: await localizeEsgError('ESG_GRID_FACTOR_YEAR_INVALID') }
    if (value === null || !Number.isFinite(value)) return { error: await localizeEsgError('ESG_GRID_FACTOR_VALUE_INVALID') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('esg_set_grid_factor', {
        p_year: year, p_kg_co2_per_kwh: value, p_source: input.source, p_reason: blank(input.reason) ?? undefined,
    })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/energy')
    revalidatePath('/safety')
    return {}
}

export async function setStandardHours(hours: string): Promise<EsgState> {
    const h = numOrNull(hours)
    if (h === null || !Number.isFinite(h)) return { error: await localizeEsgError('ESG_STANDARD_HOURS_INVALID') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('esg_set_standard_hours', { p_hours: h })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/rates')
    revalidatePath('/safety')
    return {}
}

export async function saveRequiredTraining(input: {
    id: string | null; name: string; category: string; validityMonths: string; appliesTo: string; positionIds: string[]; notes: string
}): Promise<EsgState> {
    const validity = numOrNull(input.validityMonths)
    if (validity !== null && !Number.isInteger(validity)) return { error: await localizeEsgError('REQUIRED_TRAINING_VALIDITY_INVALID') }
    if (input.id !== null && !UUID.test(input.id)) return { error: await localizeEsgError('REQUIRED_TRAINING_NOT_FOUND') }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('required_training_save', {
        p_id: input.id as string, p_name: input.name, p_category: blank(input.category) as string, p_validity_months: validity as number,
        p_applies_to: input.appliesTo, p_position_ids: input.appliesTo === 'positions' ? input.positionIds.filter((p) => UUID.test(p)) : [],
        p_notes: blank(input.notes) ?? undefined,
    })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/training')
    revalidatePath('/hr/training')
    return { id: (data as { id: string } | null)?.id }
}

export async function retireRequiredTraining(id: string): Promise<EsgState> {
    if (!UUID.test(id)) return { error: await localizeEsgError('REQUIRED_TRAINING_NOT_FOUND') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('required_training_retire', { p_id: id })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/training')
    revalidatePath('/hr/training')
    return {}
}

export async function recordPolicy(input: {
    supersedesId: string | null; title: string; version: string; ownerId: string; effective: string; review: string; documentRef: string
}): Promise<EsgState> {
    if (!UUID.test(input.ownerId)) return { error: await localizeEsgError('COMPANY_POLICY_OWNER_NOT_FOUND') }
    if (!input.effective || !input.review) return { error: await localizeEsgError('COMPANY_POLICY_DATES_REQUIRED') }
    if (input.supersedesId !== null && !UUID.test(input.supersedesId)) return { error: await localizeEsgError('COMPANY_POLICY_NOT_FOUND') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('company_policy_record', {
        p_supersedes_id: input.supersedesId as string, p_title: input.title, p_version: input.version, p_owner_employee_id: input.ownerId,
        p_effective_date: input.effective, p_review_date: input.review, p_document_ref: input.documentRef,
    })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/policies')
    revalidatePath('/safety')
    return {}
}

export async function recordOutsideReport(input: {
    receivedOn: string; receivedVia: string; reporterName: string; subject: string; details: string; concernsCco: boolean | null
}): Promise<EsgState> {
    if (input.concernsCco === null) return { error: await localizeEsgError('WHISTLEBLOWING_CONCERNS_CCO_REQUIRED') }
    if (!input.receivedOn) return { error: await localizeEsgError('WHISTLEBLOWING_RECEIVED_ON_REQUIRED') }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('whistleblowing_report_record_outside', {
        p_received_on: input.receivedOn, p_received_via: input.receivedVia, p_reporter_name: blank(input.reporterName) as string,
        p_subject: input.subject, p_details: input.details, p_concerns_cco: input.concernsCco,
    })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath('/safety/whistleblowing')
    revalidatePath('/safety')
    return { id: (data as { id: string } | null)?.id }
}

export async function addReportUpdate(reportId: string, status: string, note: string): Promise<EsgState> {
    if (!UUID.test(reportId)) return { error: await localizeEsgError('WHISTLEBLOWING_NOT_FOUND') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('whistleblowing_report_update', { p_report_id: reportId, p_status: status, p_note: note })
    if (error) return { error: await localizeEsgError(error.message) }
    revalidatePath(`/safety/whistleblowing/${reportId}`)
    revalidatePath('/safety/whistleblowing')
    revalidatePath('/safety')
    return {}
}
