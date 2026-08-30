import { getTranslations } from '@/lib/i18n/server'

// SO-4b:报价的具名拒绝。【与销售订单那一族同一个形状】:不在集合里的
// 是真正未编码的数据库错误,原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
const QUOTE_ERROR_CODES = new Set([
    'QT_NOT_FOUND',
    // 【转换的四条,操作员天天会撞上】而每一条都带着【下一步】:
    // 先签发、这张已经转成哪张单了、它被谢绝了、改有效期再签发一版。
    'QT_NOT_ISSUED',
    'QT_EXPIRED',
    'QT_DECLINED',
    'QT_ALREADY_CONVERTED',
    'QT_NO_LINES',
    // 谢绝
    'QT_DECLINE_REASON_REQUIRED',
    // 签发
    'QT_NOT_ISSUABLE',
    // 结构性守卫:正常路径撞不到(转过的报价页面上一个可编辑控件都不画),
    // 撞上时必须说人话而不是抛触发器原文。
    'QT_CONVERTED_IMMUTABLE',
    'QT_HISTORY_IMMUTABLE',
    'QT_CONVERT_LINES_LOST',
    // 转换会调 create_sales_order —— 它的拒绝原样冒上来,所以也要认得
    'ORDER_DATE_REQUIRED',
    'SO_CREATE_CUSTOMER_INVALID',
    'SO_CREATE_FX_INVALID',
    'SO_CREATE_NO_LINES',
    'SO_CREATE_LINE_INVALID',
    'SO_CREATE_LINES_LOST',
    'CURRENCY_INVALID',
    // PROC-BUILD-1(R5):可售性。三条句子,三种下一步动作 —— 见 saleErrorCodes.ts 的同一段。
    'SALE_FORM_NOT_SALEABLE', 'SALE_FORM_NOT_SET',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export function isQuoteErrorCode(message: string | null | undefined): boolean {
    const m = (message ?? '').trim().match(CODE_RE)
    return !!m && QUOTE_ERROR_CODES.has(m[1])
}

export async function localizeQuoteError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.restricted')
    if (!match || !QUOTE_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('quotes.errors.' + match[1], params)
}
