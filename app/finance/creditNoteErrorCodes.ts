import { getTranslations } from '@/lib/i18n/server'

// CN-1:贷项凭证的具名拒绝。【与库存/销售那两族同一个形状】:不在集合里的
// 是真正未编码的数据库错误,原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
const CREDIT_NOTE_ERROR_CODES = new Set([
    // 【操作员天天会撞上前五条】—— 这张发票不能开贷项凭证(种类不对/已作废/
    // 已结清)、忘了写理由、忘了填单据日、三条天花板中的一条超了。
    // 每一条都带着【数字】和【下一步】。
    'CN_INVOICE_NOT_FOUND',
    'CN_INVOICE_NOT_ORDER_KIND',
    'CN_INVOICE_VOID',
    'CN_INVOICE_FULLY_SETTLED',
    'CN_REASON_REQUIRED',
    'CN_NOTE_DATE_REQUIRED',
    'CN_NO_LINES',
    'CN_LINE_INVALID',
    // 三条天花板 —— 各自报出【想冲多少】与【最多能冲多少】
    'CN_EXCEEDS_OPEN',
    'CN_EXCEEDS_UNRELEASED',
    'CN_EXCEEDS_RELEASED',
    // 结构性守卫:正常路径撞不到(页面只列这张发票自己的行),撞上时说人话
    'CN_LINE_WRONG_INVOICE',
    'CN_BASIS_MISMATCH',
    'CN_BALANCE_MISSING',
    'CN_LINES_LOST',
    'CN_NOT_FOUND',
    'CREDIT_NOTE_IMMUTABLE',
    // 期间锁 / 年结闸由 post_journal_entry 统一执行,凭证会原样撞上它们
    'PERIOD_LOCKED',
    'YEAR_CLOSED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export function isCreditNoteErrorCode(message: string | null | undefined): boolean {
    const m = (message ?? '').trim().match(CODE_RE)
    return !!m && CREDIT_NOTE_ERROR_CODES.has(m[1])
}

export async function localizeCreditNoteError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.restricted')
    if (!match || !CREDIT_NOTE_ERROR_CODES.has(match[1])) return raw
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('cn.errors.' + match[1], params)
}
