import { getTranslations } from '@/lib/i18n/server'

// STK-1:库存状态(暂扣/释放)相关的数据库错误码。端口自 assayErrorCodes.ts。
// 不在集合内的是真正未编码的数据库错误,【原样返回】。
const STOCK_ERROR_CODES = new Set([
    'STK_HOLD_EXCEEDS_AVAILABLE',
    'STK_RELEASE_EXCEEDS_HELD',
    'STK_REASON_REQUIRED',
    'STK_QTY_INVALID',
    'STK_ONE_BATCH',
    // 桶不许为负 —— 正常路径撞不到它(hold/release 先按名拒绝了),
    // 但它是最后一道结构性守卫,撞上时必须说人话而不是抛一句触发器原文。
    'STK_NEGATIVE_BUCKET',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeStockError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }
    if (!match || !STOCK_ERROR_CODES.has(match[1])) {
        return raw
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return (await getTranslations())('stock.errors.' + code, params)
}
