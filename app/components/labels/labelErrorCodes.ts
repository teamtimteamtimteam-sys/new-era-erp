import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-3b(2026-10-07,MES-3b Step 0 Q6–Q8,Tim):印标签的具名拒绝(label_print_context · record_label_print)。
// 【与库存、销售那几族同一个形状】:不在集合里的是真正未编码的数据库错误,交给共用兜底 lib/machine-text.ts。
// PERMISSION_DENIED 说出它要哪一个码(common.actionMessage.permissionDenied,与按下之后那一句同一句 —— DBLOCK-1)。
const LABEL_ERROR_CODES = new Set([
    'LABEL_KIND_INVALID',
    'LABEL_OBJECT_NOT_FOUND',
    'LABEL_TEMPLATE_NONE',
    'LABEL_TEMPLATE_INVALID',
    'LABEL_COPIES_INVALID',
    'LABEL_REPRINT_REASON_REQUIRED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeLabelError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    const t = await getTranslations()
    if (match && match[1] === 'PERMISSION_DENIED') return t('common.actionMessage.permissionDenied', { 0: match[2] ?? '' })
    if (!match || !LABEL_ERROR_CODES.has(match[1])) return await fallbackForRawError(raw, 'localizeLabelError@app/components/labels/labelErrorCodes.ts')
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('labels.errors.' + match[1], params)
}
