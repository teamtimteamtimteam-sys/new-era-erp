import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'

// MES-1(2026-10-06):设备登记、网关钥匙、采集上限与数据收件箱的拒绝 → 人话。
//
// 【两种来源,一支映射器】
//   ① 函数按名抛的码(save_device / retire_device / issue_gateway_key / revoke_gateway_key / set_ingest_settings /
//      retry_inbox_row / discard_inbox_row 与它们的守卫):`CODE|参数0|…`。
//   ② 表上的 CHECK 约束名(devices 的形状):Postgres 把名字原样印在消息里 —— 按名字认,与 equipmentErrorCodes 同一个做法。
// 【加一条 = 来这里加一个名字】check-i18n 的 devices.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const DEVICE_ERROR_CODES = new Set([
    // ── 设备登记 ──────────────────────────────────────────────────────────
    'DEVICE_NOT_FOUND', 'DEVICE_FIELD_UNKNOWN', 'DEVICE_KIND_FIXED', 'DEVICE_CODE_FIXED', 'DEVICE_RETIRED',
    'DEVICE_NEVER_DELETED', 'DEVICE_GATEWAY_INVALID', 'DEVICE_EQUIPMENT_UNKNOWN', 'DEVICE_CLASS_UNKNOWN',
    'DEVICE_RETIRE_REASON_REQUIRED',
    // ── 网关钥匙 ──────────────────────────────────────────────────────────
    'GATEWAY_KEY_NOT_A_GATEWAY', 'GATEWAY_KEY_GATEWAY_RETIRED', 'GATEWAY_KEY_TWO_ACTIVE', 'GATEWAY_KEY_ONLY_REVOKE',
    'GATEWAY_KEY_ALREADY_REVOKED', 'GATEWAY_KEY_NEVER_DELETED', 'GATEWAY_KEY_REVOKE_REASON_REQUIRED', 'GATEWAY_KEY_NOT_FOUND',
    // ── 采集上限 ──────────────────────────────────────────────────────────
    'INGEST_SETTING_UNKNOWN', 'INGEST_SETTING_INVALID', 'INGEST_SETTINGS_MISSING',
    // ── 数据收件箱 ────────────────────────────────────────────────────────
    'INBOX_ROW_NOT_FOUND', 'INBOX_ROW_FROZEN', 'INBOX_NOT_RETRIABLE', 'INBOX_NOT_DISCARDABLE',
    'INBOX_DISCARD_REASON_REQUIRED', 'INBOX_THROUGH_FUNCTION_ONLY', 'INBOX_ONLY_STATUS_CHANGES', 'INGEST_LOG_APPEND_ONLY',
    // ── devices 表上的约束名(数据库直接抛)─────────────────────────────────
    'devices_name_check', 'devices_capacity_check', 'devices_resolution_check', 'devices_heartbeat_interval_s_check',
    'devices_gateway_shape', 'devices_heartbeat_gateway_only', 'devices_not_own_gateway', 'devices_kind_check',
    'devices_interface_status_check',
])

const CONSTRAINT_NAMES = [...DEVICE_ERROR_CODES].filter((c) => c.startsWith('devices_'))
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeDeviceError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    const constraint = CONSTRAINT_NAMES.find((c) => raw.includes(`"${c}"`))
    if (constraint) return t('devices.errors.' + constraint)

    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !DEVICE_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeDeviceError@app/operation/devices/deviceErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('devices.errors.' + match[1], params)
}
