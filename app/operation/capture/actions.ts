'use server'

// app/operation/capture/actions.ts
// MES-2(2026-10-06,规格 §6.3;MES-0 Q10–Q13;MES-2 Step 0 Q7–Q16,Tim):确认队列上的四个动作。
//   · confirmDraft        —— 确认一张网关送来的草稿(confirm_capture_draft;action.confirm_capture)。改了读数要写理由。
//   · rejectDraft         —— 驳回(reject_capture_draft;理由必填,终局)。
//   · submitManualWeighing —— 手工录入一次称重(submit_manual_capture;同一支转换器,一步确认;仪器可选)。
//   · correctWeighing     —— 更正一次已确认的称重(correct_weighing;新的一行指回原行,理由必填)。
// 【判据一条都不在这里】谁能确认、哪些字段改得了、要不要理由、量程、地磅单的两磅与净重 —— 全部在库里裁,
//   拒绝经 refuseFromCoded 说成人话。这里只做【服务端必须独立再挡一道】的事:读数是正数、理由不是空白。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeCaptureError } from './captureErrorCodes'
import { positiveKg, subjectJson, type Subject } from './captureFields'

function refresh() {
    revalidatePath('/operation/capture')
    revalidatePath('/operation/weighbridge')
    revalidatePath('/operation/capture/inbox')
    revalidatePath('/tools/reminders')
}

async function needKg(raw: string, field: string): Promise<{ ok: true; kg: number } | { ok: false; out: ActionOutcome }> {
    const kg = positiveKg(raw)
    if (kg === null) return { ok: false, out: { error: (await getTranslations())('capture.form.needPositiveKg'), field } }
    return { ok: true, kg }
}

export async function confirmDraft(draftId: string, proposedKg: number, weightRaw: string, reason: string, subject: Subject):
    Promise<ActionOutcome & { weighingId?: string }> {
    const w = await needKg(weightRaw, 'weight')
    if (!w.ok) return w.out
    const changed = w.kg !== proposedKg
    if (changed && reason.trim() === '') return { error: (await getTranslations())('capture.errors.CAPTURE_CHANGE_REASON_REQUIRED', { 0: 'weight_kg' }), field: 'reason' }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('confirm_capture_draft', {
        p_draft_id: draftId,
        p_overrides: changed ? { weight_kg: w.kg } : {},
        p_reasons: changed ? { weight_kg: reason.trim() } : {},
        p_subject: subjectJson(subject),
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh()
    return { success: true, weighingId: data as string }
}

export async function rejectDraft(draftId: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('capture.errors.CAPTURE_REJECT_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('reject_capture_draft', { p_draft_id: draftId, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh()
    return { success: true }
}

export async function submitManualWeighing(fields: { deviceId: string | null; weight: string; weighedAt: string | null; subject: Subject }):
    Promise<ActionOutcome & { weighingId?: string; ticketId?: string | null }> {
    const w = await needKg(fields.weight, 'weight')
    if (!w.ok) return w.out
    // 读数的时刻(datetime-local,厂里的钟):给了就是现场时间;没给 = 确认的这一刻
    let at: string | null = null
    if (fields.weighedAt && fields.weighedAt.trim() !== '') {
        const d = new Date(fields.weighedAt)
        if (Number.isNaN(d.getTime())) return { error: (await getTranslations())('capture.form.needValidTime'), field: 'weighedAt' }
        at = d.toISOString()
    }
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('submit_manual_capture', {
        p_data_class: 'weighing',
        p_payload: { weight_kg: w.kg },
        ...(fields.deviceId ? { p_device_id: fields.deviceId } : {}),
        ...(at ? { p_site_to: at } : {}),
        p_subject: subjectJson(fields.subject),
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    const weighingId = (data as { weighing_id?: string } | null)?.weighing_id
    let ticketId: string | null = null
    if (weighingId && fields.subject.kind !== 'none') {
        const r = await supabase.from('weighings').select('ticket_id').eq('id', weighingId).maybeSingle()
        if (r.error) return await refuseFromCoded(r.error.message, localizeCaptureError)
        ticketId = (r.data as { ticket_id: string | null } | null)?.ticket_id ?? null
    }
    refresh()
    return { success: true, weighingId, ticketId }
}

export async function correctWeighing(weighingId: string, weightRaw: string, reason: string): Promise<ActionOutcome> {
    const w = await needKg(weightRaw, 'weight')
    if (!w.ok) return w.out
    if (reason.trim() === '') return { error: (await getTranslations())('capture.errors.WEIGHING_CORRECTION_REASON_REQUIRED'), field: 'reason' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_weighing', { p_weighing_id: weighingId, p_weight_kg: w.kg, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh()
    return { success: true }
}
