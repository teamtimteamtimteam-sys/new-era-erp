'use server'

// app/operation/devices/actions.ts
// MES-1(2026-10-06):设备登记、网关钥匙与采集上限的动作。
//
// 【判据一条都不在这里】谁能登记、发 / 撤钥匙、改上限(action.manage_devices)、一台网关最多两把有效钥匙、停用之后冻住、
// 编号与种类不动 —— 全部由 save_device / retire_device / issue_gateway_key / revoke_gateway_key / set_ingest_settings
// 与它们的守卫在库里裁,拒绝经 refuseFromCoded 说成人话。这里只做【服务端必须独立再挡一道】的事:
//   · 理由不能是空白(停用、撤钥匙):对话框挡了一次,库里还有一道,这里第三道;
//   · 数字框:正数才送(一个 "abc" 送进 numeric 是一句 Postgres 的英文,不是一句人话)。
// 【密钥只出现一次】issueGatewayKey 把 secret 原样交回给发放它的那一个浏览器会话,然后它就哪里都没有了 ——
//   不写日志、不进任何缓存;页面显示一次,关掉就没了(MES-0 Q5)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { refuseFromCoded, type ActionOutcome } from '@/lib/action-refusal'
import { localizeDeviceError } from './deviceErrorCodes'

const TERMS = ['term_protocol', 'term_point_list', 'term_timestamp_precision', 'term_no_charge',
    'term_retention_export', 'term_documentation'] as const
const TERM_VALUES = new Set(['not_confirmed', 'confirmed', 'not_offered'])

export type DeviceFields = {
    name?: string
    kind?: string
    gateway_id?: string | null
    data_class?: string | null
    equipment_id?: string | null
    station?: string | null
    capacity?: string | null
    resolution?: string | null
    unit?: string | null
    protection_rating?: string | null
    interface_status?: string
    heartbeat_interval_s?: string | null
    notes?: string | null
} & Partial<Record<(typeof TERMS)[number], string>>

function refresh(id?: string | null) {
    revalidatePath('/operation/devices')
    if (id) revalidatePath(`/operation/devices/${id}`)
    revalidatePath('/settings/pending-values')
    revalidatePath('/tools/reminders')
}

/** 正数(或空)—— 空 = 清空那一格;不是正数就按名退回,指着那一格。 */
async function positiveOrEmpty(raw: string | null | undefined, field: string, integer: boolean): Promise<{ value: string | null } | ActionOutcome> {
    const s = (raw ?? '').trim()
    if (s === '') return { value: null }
    const n = Number(s)
    if (!Number.isFinite(n) || n <= 0 || (integer && !Number.isInteger(n))) {
        const t = await getTranslations()
        return { error: t(integer ? 'devices.form.needPositiveInteger' : 'devices.form.needPositive'), field }
    }
    return { value: String(n) }
}

export async function saveDevice(id: string | null, fields: DeviceFields): Promise<ActionOutcome & { id?: string }> {
    const t = await getTranslations()
    const payload: Record<string, string | null> = {}
    if (fields.name !== undefined) {
        if (fields.name.trim() === '') return { error: t('devices.form.needName'), field: 'name' }
        payload.name = fields.name.trim()
    }
    if (id === null) {
        if (!fields.kind) return { error: t('devices.form.needKind'), field: 'kind' }
        payload.kind = fields.kind
    }
    for (const k of ['gateway_id', 'data_class', 'equipment_id', 'station', 'unit', 'protection_rating', 'notes'] as const) {
        if (fields[k] !== undefined) payload[k] = fields[k] === null || fields[k]!.trim() === '' ? null : fields[k]!.trim()
    }
    for (const [k, integer] of [['capacity', false], ['resolution', false], ['heartbeat_interval_s', true]] as const) {
        if (fields[k] === undefined) continue
        const r = await positiveOrEmpty(fields[k], k, integer)
        if ('error' in r) return r
        payload[k] = (r as { value: string | null }).value
    }
    if (fields.interface_status !== undefined) payload.interface_status = fields.interface_status
    for (const k of TERMS) {
        const v = fields[k]
        if (v === undefined) continue
        if (!TERM_VALUES.has(v)) return { error: t('devices.form.termInvalid'), field: k }
        payload[k] = v
    }

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('save_device', { p_fields: payload, p_id: id ?? undefined })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    const savedId = (data as string | null) ?? id
    refresh(savedId)
    return { success: true, id: savedId ?? undefined }
}

export async function retireDevice(id: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('devices.errors.DEVICE_RETIRE_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('retire_device', { p_id: id, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh(id)
    return { success: true }
}

/** 发一把钥匙 —— secret 只在这一次的返回值里。 */
export async function issueGatewayKey(gatewayId: string): Promise<ActionOutcome & { secret?: string; prefix?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('issue_gateway_key', { p_gateway_id: gatewayId })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    const issued = data as { key_id: string; prefix: string; secret: string } | null
    if (!issued?.secret) return { error: (await getTranslations())('devices.keys.issueNoSecret') }
    refresh(gatewayId)
    return { success: true, secret: issued.secret, prefix: issued.prefix }
}

export async function revokeGatewayKey(gatewayId: string, keyId: string, reason: string): Promise<ActionOutcome> {
    if (reason.trim() === '') return { error: (await getTranslations())('devices.errors.GATEWAY_KEY_REVOKE_REASON_REQUIRED') }
    const supabase = await createClient()
    const { error } = await supabase.rpc('revoke_gateway_key', { p_key_id: keyId, p_reason: reason.trim() })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh(gatewayId)
    return { success: true }
}

export type IngestSettingsFields = Partial<Record<'fail_budget' | 'fail_window_s' | 'global_reject_budget' |
    'max_payload_bytes' | 'max_messages' | 'clock_ahead_s', string>>

export async function saveIngestSettings(fields: IngestSettingsFields): Promise<ActionOutcome> {
    const t = await getTranslations()
    const payload: Record<string, number> = {}
    for (const [k, v] of Object.entries(fields)) {
        const n = Number((v ?? '').trim())
        if (!Number.isInteger(n) || n <= 0) return { error: t('devices.form.needPositiveInteger'), field: k }
        payload[k] = n
    }
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_ingest_settings', { p_fields: payload })
    if (error) return await refuseFromCoded(error.message, localizeDeviceError)
    refresh()
    return { success: true }
}
