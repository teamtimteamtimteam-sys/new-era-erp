import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'
import { refusePermission } from '@/lib/action-refusal'

// MES-5a-2(2026-10-08,MES-5a Step 0 Q20 · Q24 · Q27 · Q28):电表读数与电费分摊的拒绝 → 人话。
//   ① 函数按名抛的码(record / correct_meter_reading · meter_reading_internal · electricity_allocation_compute ·
//      preview / post_electricity_allocation · set_electricity_shared_pool_rule):`CODE|参数0|…`。
//   ② 表上的约束名(meter_readings 的形状):Postgres 把名字原样印在消息里 —— 按名字认。
// 【加一条 = 来这里加一个名字】check-i18n 的 energy.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
const ENERGY_ERROR_CODES = new Set([
    // ── 电表读数 ──────────────────────────────────────────────────────────
    'METER_READING_DEVICE_NOT_METER', 'METER_READING_TIME_REQUIRED', 'METER_READING_IN_FUTURE', 'METER_READING_VALUE_INVALID',
    'METER_RESET_REASON_REQUIRED', 'METER_READING_TIME_TAKEN', 'METER_READING_BELOW_PREVIOUS', 'METER_READING_ABOVE_NEXT',
    'METER_READING_NOT_FOUND', 'METER_READING_SUPERSEDED', 'METER_CORRECTION_REASON_REQUIRED', 'METER_READING_CORRECTION_SAME_VALUE',
    // ── 电费分摊 ──────────────────────────────────────────────────────────
    'ELECTRICITY_PERIOD_REQUIRED', 'ELECTRICITY_PERIOD_INVALID', 'ELECTRICITY_PERIOD_IN_FUTURE', 'ELECTRICITY_BILL_AMOUNT_INVALID',
    'ELECTRICITY_BILL_KWH_INVALID', 'ELECTRICITY_BILL_CURRENCY_REQUIRED', 'ELECTRICITY_BILL_CURRENCY_NOT_BASE', 'ELECTRICITY_BANK_NOT_BASE',
    'ELECTRICITY_PERIOD_OVERLAPS', 'ELECTRICITY_RUN_ALREADY_ALLOCATED', 'ELECTRICITY_RUN_TIME_MISSING', 'ELECTRICITY_RUN_TIME_ZERO',
    'ELECTRICITY_METERED_EXCEEDS_BILL', 'ELECTRICITY_INVOICE_REF_REQUIRED', 'ELECTRICITY_SETTINGS_MISSING',
    'BASE_CURRENCY_NOT_SET', 'PAYMENT_STATUS_INVALID', 'SUPPLIER_REQUIRED_FOR_UNPAID', 'SUPPLIER_NOT_FOUND',
    'EXPENSE_DATE_REQUIRED', 'DOCUMENT_DATE_IN_FUTURE', 'COST_ENTRY_ALREADY_SETTLED', 'PERIOD_LOCKED', 'APPEND_ONLY',
    // ── MES-5b-2(Step 0 Q22 · Q24 · Q26):撤回一张电费单(reverse_electricity_allocation 与它经 reverse_expense_internal 抛的)──
    'ELECTRICITY_REVERSAL_REASON_REQUIRED', 'ELECTRICITY_ALLOCATION_NOT_FOUND', 'ELECTRICITY_ALLOCATION_ALREADY_REVERSED',
    'ELECTRICITY_ALLOCATION_STATE_CHANGED', 'ELECTRICITY_REVERSAL_DATE_SPLIT', 'EXPENSE_HAS_SETTLEMENT', 'EXPENSE_HAS_PREPAYMENT_APPLIED',
    'EXPENSE_ALREADY_REVERSED', 'EXPENSE_NOT_FOUND', 'COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY',
    // ── meter_readings 表上的约束名(数据库直接抛)────────────────────────────
    'meter_readings_reset_shape', 'meter_readings_correction_shape', 'meter_readings_register_kwh_check',
])

const CONSTRAINT_NAMES = [...ENERGY_ERROR_CODES].filter((c) => c.startsWith('meter_readings_'))
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeEnergyError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const constraint = CONSTRAINT_NAMES.find((c) => raw.includes(`"${c}"`))
    if (constraint) return t('energy.errors.' + constraint)
    const match = raw.match(CODE_RE)
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await refusePermission(match[2] ?? '')).error
    }
    if (!match || !ENERGY_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeEnergyError@app/finance/electricity/energyErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('energy.errors.' + match[1], params)
}
