import { getTranslations } from '@/lib/i18n/server'

// SO-1:销售订单的具名拒绝。【与库存那一族同一个形状】:不在集合里的
// 是真正未编码的数据库错误,原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
const SALES_ORDER_ERROR_CODES = new Set([
    'SO_NOT_FOUND',
    'SO_NO_LINES',
    'SO_TRANSITION_NOT_ALLOWED',
    'SO_CANCEL_REASON_REQUIRED',
    'SO_CUSTOMER_ON_HOLD',
    'SO_CONFIRMED_IMMUTABLE',
    'SO_STATUS_NOT_EDITABLE',
    'SO_NOT_ISSUABLE',
    'SO_ISSUE_IMMUTABLE',
    'SO_HISTORY_IMMUTABLE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export function isSalesOrderErrorCode(message: string | null | undefined): boolean {
    const m = (message ?? '').trim().match(CODE_RE)
    return !!m && SALES_ORDER_ERROR_CODES.has(m[1])
}

export async function localizeSalesOrderError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.restricted')
    if (!match || !SALES_ORDER_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('sales.errors.' + match[1], params)
}
