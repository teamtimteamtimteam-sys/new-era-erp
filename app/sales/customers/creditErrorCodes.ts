// ROLE-1 Batch 2a(Tim,Q11):客户信用限额与冻结那条路上的具名拒绝 → 双语句子。
// 形状逐字取自 contactErrorCodes(本仓库已有九处同形)。码逐条取自
// db/functions/set_customer_credit.sql 与 db/functions/guard_customer_credit_write.sql。
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

const CREDIT_ERROR_CODES = new Set([
    'CUSTOMER_CREDIT_THROUGH_FUNCTION_ONLY',
    'CUSTOMER_CREDIT_HOLD_REQUIRED',
    'CUSTOMER_CREDIT_LIMIT_INVALID',
    'CUSTOMER_NOT_FOUND',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeCreditError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match || !CREDIT_ERROR_CODES.has(match[1])) {
        return await fallbackForRawError(raw, 'localizeCreditError@app/sales/customers/creditErrorCodes.ts')
    }
    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    }
    return (await getTranslations())('customers.creditErrors.' + code, params)
}
