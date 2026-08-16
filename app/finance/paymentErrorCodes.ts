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
    // PAY-1:冲销那条路上的三个码。此前它们【不在集合里】,于是 localize 把原文
    // 原样返回 —— 屏幕上就是 PAYMENT_ALREADY_REVERSED 这样一串机器串。
    // REVERSAL_DATE_REQUIRED 的文案 FIN-10 就写好了(finance.errors 下),
    // 只是没有人把这个码编进任何一个集合,所以那句人话一直没被用上。
    'PAYMENT_NOT_FOUND', 'PAYMENT_ALREADY_REVERSED', 'REVERSAL_DATE_REQUIRED',
    // FIN-22 / FA-1a:固定资产。处置与投用经这条路报出来(月结的动作都走
    // month-end/actions.ts,而它统一用这个本地化器)。
    'ASSET_NOT_FOUND', 'ASSET_ALREADY_DISPOSED', 'ASSET_ALREADY_IN_SERVICE',
    'ASSET_DISPOSED', 'DISPOSAL_BEFORE_ACQUISITION', 'PROCEEDS_INVALID',
    'IN_SERVICE_BEFORE_ACQUISITION',
    // FA-1a:折旧还欠着就锁不进去 —— 这一条会在月结的关账按钮上冒出来
    'DEPRECIATION_OUTSTANDING',
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
