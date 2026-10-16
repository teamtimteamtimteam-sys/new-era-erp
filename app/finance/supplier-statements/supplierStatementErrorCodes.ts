import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

// MES-8a:供应商对账单一族 DB 函数(supplier_statement_data / issue_supplier_statement / record_supplier_statement_issue)抛出的错误码。
// 【逐条从函数体枚举出来的】。不在集合内的是真正未编码的 DB 错误,交给共用兜底 lib/machine-text.ts。
export const SUPPLIER_STATEMENT_ERROR_CODES = new Set([
    'SUPPLIER_NOT_FOUND',
    'SUPPLIER_STATEMENT_PERIOD_REQUIRED',
    'SUPPLIER_STATEMENT_PERIOD_INVALID',
    'SUPPLIER_STATEMENT_PERIOD_FUTURE',
    'SUPPLIER_STATEMENT_PRICES_RESTRICTED',
    'SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED',
    'SUPPLIER_STATEMENT_DOES_NOT_TIE',
    'SUPPLIER_STATEMENT_SUPERSEDE_REASON_REQUIRED',
    'SUPPLIER_STATEMENT_REASON_WITHOUT_SUPERSEDE',
    'SUPPLIER_STATEMENT_NOT_FOUND',
    'SUPPLIER_STATEMENT_SUPERSEDED',
    'SUPPLIER_STATEMENT_ISSUE_PATH_INVALID',
    'SUPPLIER_STATEMENT_SHA_INVALID',
    'SUPPLIER_STATEMENT_BYTES_ALREADY_RECORDED',
    'SUPPLIER_STATEMENT_IMMUTABLE',
    'SUPPLIER_STATEMENT_ISSUE_IMMUTABLE',
    'SUPPLIER_STATEMENT_DATE_REQUIRED',
    'SUPPLIER_STATEMENT_COMPANY_PROFILE_INCOMPLETE',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeSupplierStatementError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match) return await fallbackForRawError(raw, 'localizeSupplierStatementError@app/finance/supplier-statements/supplierStatementErrorCodes.ts')
    const t = await getTranslations()
    if (match[1] === 'PERMISSION_DENIED') return t('permissions.errDenied')
    if (!SUPPLIER_STATEMENT_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeSupplierStatementError@app/finance/supplier-statements/supplierStatementErrorCodes.ts')
    }
    const params: Record<string, string> = {}
    if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('supplierStatements.errors.' + match[1], params)
}
