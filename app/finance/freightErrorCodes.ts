import { getTranslations } from '@/lib/i18n/server'

// record_freight_document 抛出的错误码。未编码的其它错误原样返回。
// 【每一条都是一次"不猜"的拒绝】—— value 口径遇未计价批次、weight 口径遇混合单位、
// stated 口径加总对不上、GST 被要求资本化,都是宁可停下也不要给一个看不见的错数。
const FREIGHT_ERROR_CODES = new Set([
    'FREIGHT_DATE_REQUIRED', 'FREIGHT_SUPPLIER_REQUIRED', 'FREIGHT_AMOUNT_INVALID',
    'FREIGHT_BASIS_INVALID', 'FREIGHT_NO_BATCHES', 'FREIGHT_DUPLICATE_BATCH',
    'FREIGHT_BATCH_UNPRICED', 'FREIGHT_MIXED_UNITS', 'FREIGHT_BASIS_ZERO',
    'FREIGHT_STATED_AMOUNT_REQUIRED', 'FREIGHT_STATED_AMOUNT_INVALID',
    'FREIGHT_STATED_SUM_MISMATCH', 'FREIGHT_GST_NOT_CAPITALISABLE',
    'FREIGHT_PAYMENT_STATUS_INVALID', 'INBOUND_NOT_FOUND', 'BANK_ACCOUNT_REQUIRED',
    'FX_RATE_MISSING', 'PERIOD_LOCKED',
    // LOG-4a/4b:出口运费与冲销那一族。【每一条都要成句子】—— 屏幕上永远不出现裸码。
    'FREIGHT_SUPPLIER_NOT_A_FORWARDER', 'EXPORT_FREIGHT_CONTAINER_NOT_FOUND',
    'EXPORT_FREIGHT_HAS_NO_ALLOCATIONS', 'FREIGHT_NOT_FOUND',
    'FREIGHT_ALREADY_REVERSED', 'FREIGHT_HAS_SETTLEMENT',
    'FREIGHT_REVERSAL_REASON_REQUIRED', 'FREIGHT_STATUS_NO_DIRECT_UPDATE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeFreightError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match || !FREIGHT_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return (await getTranslations())('finance.freight.errors.' + match[1], params)
}
