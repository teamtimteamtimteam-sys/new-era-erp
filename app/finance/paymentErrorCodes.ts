import { getTranslations } from '@/lib/i18n/server'

// record_payment / reverse_payment 抛出的错误码(端口自 financeErrorCodes.ts)。
// FX_RATE_REQUIRED / PERIOD_LOCKED 复用 finance.errors 里已有的文案。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PAYMENT_ERROR_CODES = new Set([
    'PAYMENT_DATE_REQUIRED',
    'ALLOC_CURRENCY_MISMATCH', 'TRANSFER_SAME_ACCOUNT', 'TRANSFER_AMOUNTS_UNEQUAL',
    'TRANSFER_NOT_FOUND', 'TRANSFER_ALREADY_REVERSED', 'DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'DIRECTION_INVALID', 'COUNTERPARTY_NOT_FOUND', 'AMOUNT_INVALID',
    'FX_RATE_REQUIRED', 'BANK_INVALID',
    'ALLOC_WRONG_SIDE', 'ALLOC_WRONG_PARTY', 'ALLOC_UNPRICED',
    'ALLOC_EXCEEDS', 'ALLOC_EXCEEDS_PAYMENT', 'PERIOD_LOCKED',
])

// cut 4b:record_payment 的 PO 预付分支抛的码,文案住在 purchasing.errors 下
// (同一个码在采购侧与付款侧要说同一句话)。
const PURCHASING_SIDE_CODES = new Set(['PREPAY_EXCEEDS_ESTIMATE'])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePaymentError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || (!PAYMENT_ERROR_CODES.has(match[1]) && !PURCHASING_SIDE_CODES.has(match[1]))) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    const t = await getTranslations()
    return PURCHASING_SIDE_CODES.has(code)
        ? t('purchasing.errors.' + code, params)
        : t('finance.errors.' + code, params)
}
