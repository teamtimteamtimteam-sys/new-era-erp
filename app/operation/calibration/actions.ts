'use server'

// app/operation/calibration/actions.ts
// MES-2(2026-10-06,规格 §8.2;MES-0 Q30 · Q31;MES-2 Step 0 Q23–Q26 · Q30,Tim):校准页的动作。
//   · recordCalibration —— 记一次校准(record_instrument_calibration;action.manage_devices)。校准日与证书有效期必填。
//   · voidCalibration   —— 作废一条记错的(理由必填);不改、不删。
//   · saveCalibrationSettings —— 两样设定(set_ingest_settings):V8 提前天数、校准规则的开关(一个日期;空 = 关)。
// 判据全在库里;这里只再挡一道"日期像日期、天数是正整数、理由不是空白"。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeCaptureError } from '@/app/operation/capture/captureErrorCodes'

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/

function refresh(deviceId?: string) {
    revalidatePath('/operation/calibration')
    revalidatePath('/operation/capture')
    revalidatePath('/operation/weighbridge')
    if (deviceId) revalidatePath(`/operation/devices/${deviceId}`)
    revalidatePath('/settings/pending-values')
    revalidatePath('/tools/reminders')
}

export async function recordCalibration(f: {
    deviceId: string; calibratedOn: string; validUntil: string; result: string; certificateNo: string; body: string; notes: string
}): Promise<ActionOutcome> {
    const t = await getTranslations()
    if (!DATE_RE.test(f.calibratedOn)) return { error: t('capture.errors.CALIBRATION_DATE_REQUIRED'), field: 'calibratedOn' }
    if (!DATE_RE.test(f.validUntil)) return { error: t('capture.errors.CALIBRATION_DATE_REQUIRED'), field: 'validUntil' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_instrument_calibration', {
        p_device_id: f.deviceId, p_calibrated_on: f.calibratedOn, p_valid_until: f.validUntil, p_result: f.result,
        ...(f.certificateNo.trim() ? { p_certificate_no: f.certificateNo.trim() } : {}),
        ...(f.body.trim() ? { p_calibrating_body: f.body.trim() } : {}),
        ...(f.notes.trim() ? { p_notes: f.notes.trim() } : {}),
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(f.deviceId)
    return { success: true }
}

export async function voidCalibration(id: number, deviceId: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('capture.errors.CALIBRATION_VOID_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('void_instrument_calibration', { p_id: id, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh(deviceId)
    return { success: true }
}

/** 空串 = 清空(V8 回到 "Not yet set";开关回到关)。 */
export async function saveCalibrationSettings(leadDays: string, requireSince: string): Promise<ActionOutcome> {
    const t = await getTranslations()
    const lead = leadDays.trim()
    const since = requireSince.trim()
    if (lead !== '' && !/^[1-9]\d{0,4}$/.test(lead)) return { error: t('calibration.needLeadDays'), field: 'lead' }
    if (since !== '' && !DATE_RE.test(since)) return { error: t('capture.errors.INGEST_SETTING_INVALID', { 0: 'require_calibrated_since' }), field: 'since' }
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_ingest_settings', {
        p_fields: { calibration_lead_days: lead === '' ? null : Number(lead), require_calibrated_since: since === '' ? null : since },
    })
    if (error) return await refuseFromCoded(error.message, localizeCaptureError)
    refresh()
    return { success: true }
}
