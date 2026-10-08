'use server'

// MES-5a-2(2026-10-08,MES-5a Step 0 Q20,Tim):电表设备页上的读数 —— 记一条、更正 / 撤回一条。
//   判据全在库里(meter_reading_internal):这台设备是一台没停用的电表、时刻不在将来、比前一条小要标成寄存器清零并写理由、
//   不比后面那一条大、同一刻只有一条;更正要理由、只能更正链的末端。码:action.confirm_capture(库里问同一个)。
//   这里只把输入框的字符串变成参数(空就是没给,交给库按名拒),再把拒绝说成人话。
//   【读数时刻没有默认值】它决定这条读数落在哪一段 —— 也就决定一张电费单分到哪几炉;空就送 null,库按名拒(AGENTS.md
//   「Dates and amounts that decide a period: required, never defaulted」),页面上的按钮也在它为空时按不下去。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeEnergyError } from '@/app/finance/electricity/energyErrorCodes'

export type ReadingInput = { readAt: string; registerKwh: string; reset: boolean; resetReason: string; notes: string }

const opt = (s: string) => (s.trim() === '' ? undefined : s.trim())
const req = (s: string) => (s.trim() === '' ? null : s.trim()) as string

/** 写不成数的不能送过去(JSON 里 NaN 是 null,而 null 在这里的意思是"没给")—— 按库里那条码说出来。 */
async function kwhOf(raw: string): Promise<{ value: number | null } | { error: string }> {
    const s = raw.trim()
    if (s === '') return { value: null }
    const n = Number(s)
    if (!Number.isFinite(n)) return { error: await localizeEnergyError('METER_READING_VALUE_INVALID') }
    return { value: n }
}

function refresh(deviceId: string) {
    revalidatePath(`/operation/devices/${deviceId}`)
    revalidatePath('/finance/electricity')
}

export async function recordMeterReading(deviceId: string, r: ReadingInput): Promise<{ error?: string }> {
    const k = await kwhOf(r.registerKwh)
    if ('error' in k) return k
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_meter_reading', {
        p_device_id: deviceId, p_read_at: req(r.readAt), p_register_kwh: k.value as number,
        p_register_reset: r.reset, p_reset_reason: r.reset ? opt(r.resetReason) : undefined, p_notes: opt(r.notes),
    })
    if (error) return { error: await localizeEnergyError(error.message) }
    refresh(deviceId)
    return {}
}

export async function correctMeterReading(deviceId: string, readingId: number, r: ReadingInput & { withdraw: boolean }, reason: string): Promise<{ error?: string }> {
    const t = await getTranslations()
    if (reason.trim() === '') return { error: t('energy.errors.METER_CORRECTION_REASON_REQUIRED') }
    const k = await kwhOf(r.registerKwh)
    if ('error' in k) return k
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_meter_reading', {
        p_reading_id: readingId, p_reason: reason.trim(),
        p_read_at: r.withdraw ? undefined : opt(r.readAt), p_register_kwh: r.withdraw ? undefined : (k.value ?? undefined),
        p_register_reset: r.withdraw ? undefined : r.reset, p_reset_reason: r.withdraw || !r.reset ? undefined : opt(r.resetReason),
        p_withdraw: r.withdraw, p_notes: r.withdraw ? undefined : opt(r.notes),
    })
    if (error) return { error: await localizeEnergyError(error.message) }
    refresh(deviceId)
    return {}
}
