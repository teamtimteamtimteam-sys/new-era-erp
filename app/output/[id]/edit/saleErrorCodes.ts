import { getTranslations } from '@/lib/i18n/server'

// record_output_sale 抛出的错误码。未编码的其它错误用 saveError 包一层原文。
// 镜像 app/processing/errorCodes.ts 的 CODE|params 宽松解析。
const SALE_ERROR_CODES = new Set([
    'SALE_DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'OUTPUT_NOT_FOUND', 'OUTPUT_DELETED', 'SALE_QTY_INVALID', 'SALE_EXCEEDS_REMAINING',
    // cut 1 — 销售必须带价
    'SALE_PRICE_INVALID', 'CURRENCY_INVALID', 'FX_RATE_REQUIRED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeSaleError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const match = raw.match(CODE_RE)

    if (!match || !SALE_ERROR_CODES.has(match[1])) {
        return t('output.sale.saveError', { message: raw })
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v
        })
    }
    return t('output.sale.errors.' + code, params)
}
