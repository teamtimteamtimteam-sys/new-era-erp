import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'

// MES-2(2026-10-06):草稿确认、手工录入、更正、地磅单、份、照片、校准记录与校准闸的拒绝 → 人话。
//
// 【一支映射器,三处共用】确认队列 / 地磅单 / 校准页的动作直接用它;收货的两个动作(挂地磅单的份)、定价面板与销毁证书
//   (校准闸)在它们自己的映射器里先问 isCaptureErrorCode,是就交给这里 —— 一句码只翻一次。
// 【两种来源】① 函数按名抛的码:`CODE|参数0|…`;② 表上的约束名(数据库直接抛)—— 按名字认,与 deviceErrorCodes 同一个做法。
// 【加一条 = 来这里加一个名字】check-i18n 的 capture.errors.* 后缀集合现读下面这个 Set。
const CAPTURE_ERROR_CODES = new Set([
    // ── 草稿与确认 ────────────────────────────────────────────────────────
    'CAPTURE_DRAFT_NOT_FOUND', 'CAPTURE_DRAFT_DECIDED', 'CAPTURE_CLASS_HAS_NO_RECORD', 'CAPTURE_FIELD_FIXED',
    'CAPTURE_FIELD_UNKNOWN', 'CAPTURE_CHANGE_REASON_REQUIRED', 'CAPTURE_SUBJECT_UNKNOWN', 'CAPTURE_REJECT_REASON_REQUIRED',
    'CAPTURE_DRAFT_NEVER_DELETED', 'CAPTURE_DRAFT_ONLY_DECISION', 'CAPTURE_RECORD_APPEND_ONLY',
    // ── 手工录入 ──────────────────────────────────────────────────────────
    'CAPTURE_CLASS_UNKNOWN', 'CAPTURE_NO_MANUAL_ENTRY', 'CAPTURE_DEVICE_INVALID', 'CAPTURE_PAYLOAD_REQUIRED',
    'CAPTURE_SITE_RANGE_INVALID', 'CAPTURE_NOT_TRANSFORMED',
    // ── 称重的读数 ────────────────────────────────────────────────────────
    'WEIGHING_PAYLOAD_INVALID', 'WEIGHING_WEIGHT_INVALID', 'WEIGHING_ABOVE_CAPACITY',
    'WEIGHING_CORRECTION_REASON_REQUIRED', 'WEIGHING_NOT_FOUND', 'WEIGHING_SUPERSEDED', 'WEIGHING_CORRECTION_SAME_VALUE',
    // MES-4a(Q26):一磅已经是一条产出腿的重量 —— correct_weighing 拒(参数是那一炉的单号)
    'WEIGHING_IN_USE',
    // ── 地磅单与份 ────────────────────────────────────────────────────────
    'TICKET_DIRECTION_INVALID', 'TICKET_VEHICLE_REQUIRED', 'TICKET_NOT_FOUND', 'TICKET_VOIDED', 'TICKET_ALREADY_COMPLETE',
    'TICKET_NET_NOT_POSITIVE', 'TICKET_NOT_COMPLETE', 'TICKET_SHARE_KG_INVALID', 'TICKET_DIRECTION_MISMATCH',
    'TICKET_ALREADY_SHARED', 'TICKET_SHARE_TARGET_REQUIRED', 'SHIPMENT_LINE_NOT_FOUND', 'TICKET_VOID_REASON_REQUIRED',
    'TICKET_HAS_SHARES', 'TICKET_NEVER_DELETED', 'TICKET_FIELD_FIXED', 'TICKET_SHARE_WITHOUT_TICKET',
    'RECEIPT_QUANTITY_REASON_REQUIRED', 'RECEIPT_TICKET_NEEDS_KG',
    // ── 照片 ──────────────────────────────────────────────────────────────
    'TICKET_PHOTO_PATH_INVALID', 'TICKET_PHOTO_TYPE_INVALID', 'TICKET_PHOTO_TOO_LARGE', 'TICKET_PHOTO_WITHDRAW_REASON_REQUIRED',
    'TICKET_PHOTO_NOT_FOUND', 'TICKET_PHOTO_WITHDRAWN', 'TICKET_PHOTO_NEVER_DELETED', 'TICKET_PHOTO_ONLY_WITHDRAW',
    // ── 校准记录 ──────────────────────────────────────────────────────────
    'CALIBRATION_KIND_INVALID', 'CALIBRATION_DATE_REQUIRED', 'CALIBRATION_VALID_UNTIL_BEFORE_CALIBRATED', 'CALIBRATION_IN_FUTURE',
    'CALIBRATION_RESULT_INVALID', 'CALIBRATION_VOID_REASON_REQUIRED', 'CALIBRATION_NOT_FOUND', 'CALIBRATION_VOIDED',
    'CALIBRATION_NEVER_DELETED', 'CALIBRATION_ONLY_VOID',
    // ── 校准闸(定价 · 试算 · 销毁证书)──────────────────────────────────────
    'READING_INSTRUMENT_NOT_CALIBRATED', 'READING_INSTRUMENT_NOT_RECORDED', 'RECEIPT_READING_NOT_RECORDED',
    // ── 校准的两样设定(set_ingest_settings)────────────────────────────────
    'INGEST_SETTING_INVALID', 'INGEST_SETTING_UNKNOWN',
    // ── 表上的约束名(数据库直接抛)─────────────────────────────────────────
    'weighbridge_tickets_vehicle_reg_check', 'weighings_weight_kg_check', 'weighbridge_ticket_shares_kg_check',
])

const CONSTRAINT_NAMES = [...CAPTURE_ERROR_CODES].filter((c) => c.includes('_check'))
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

/** 这一句拒绝是不是本映射器的(收货 / 定价 / 证书的映射器用它决定转交)。 */
export function isCaptureErrorCode(message: string | null | undefined): boolean {
    const raw = (message ?? '').trim()
    if (CONSTRAINT_NAMES.some((c) => raw.includes(`"${c}"`))) return true
    const m = raw.match(CODE_RE)
    return !!m && CAPTURE_ERROR_CODES.has(m[1])
}

export async function localizeCaptureError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    const constraint = CONSTRAINT_NAMES.find((c) => raw.includes(`"${c}"`))
    if (constraint) return t('capture.errors.' + constraint)

    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !CAPTURE_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeCaptureError@app/operation/capture/captureErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('capture.errors.' + match[1], params)
}
