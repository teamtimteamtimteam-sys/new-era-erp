import { getTranslations } from '@/lib/i18n/server'

// app/inbound/codErrorCodes.ts
// COD-1:销毁证书那几支函数抛出的错误码,端口自 traceabilityErrorCodes.ts。
// 不在集合内的是真正未编码的 DB 错误,原样返回 —— 一个被翻译器吞掉的陌生错误,
// 比一串机器码更坏。
//
// 【为什么这些消息跟【界面语言】,而证书本身一律英文】
// 两个不同的收件人。证书交到【送料方】手里,他不是这套系统的用户,所以一律英文;
// 这几句拒绝是说给【按下按钮的那个人】听的,他就坐在界面前面。
const COD_ERROR_CODES = new Set([
    'BATCH_REQUIRED',
    'BATCH_NOT_FOUND',
    'NOT_AN_INBOUND_BATCH',
    'CANNOT_CERTIFY',
    'COD_NOT_FOUND',
    'COD_ALREADY_ISSUED',
    'COD_NOT_ISSUED',
    'COD_ALREADY_VOID',
    'COD_LICENCE_NOT_RECORDED',
    'COMPANY_LEGAL_NAME_MISSING',
    'SUPPLIER_NAME_MISSING',
    'REASON_REQUIRED',
])

// 【第四个状态自己的那几句】CANNOT_CERTIFY 带着一个【具名理由】上来,
// 而那个理由才是人要读的那句话 —— "还差 887 kg 没加工" 与 "这票货被注销了"
// 是两件完全不同的事,不能都显示成"不能签发"。
const CANNOT_CERTIFY_REASONS = new Set([
    'DELIVERY_WRITTEN_OFF',
    'DELIVERY_LEFT_BY_ANOTHER_DOOR',
    'NOTHING_PROCESSED',
    'DELIVERY_NOT_FULLY_PROCESSED',
    'COMPLETION_DATE_UNKNOWN',
    'BATCH_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeCodError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    // 权限拒绝不是错误,是这个人不该看见。
    if (match && match[1] === 'PERMISSION_DENIED') {
        return (await getTranslations())('common.restricted')
    }

    if (!match || !COD_ERROR_CODES.has(match[1])) return raw

    const code = match[1]
    const parts = match[2] ? match[2].split('|') : []

    const t = await getTranslations()

    if (code === 'CANNOT_CERTIFY') {
        const [batch, reason] = parts
        const why = reason && CANNOT_CERTIFY_REASONS.has(reason)
            ? t('cod.cannotCertify.' + reason, { 0: batch ?? '' })
            : (reason ?? '')
        return t('cod.errors.CANNOT_CERTIFY', { 0: batch ?? '', 1: why })
    }

    const params: Record<string, string> = {}
    parts.forEach((v, i) => { params[String(i)] = v })
    return t('cod.errors.' + code, params)
}
