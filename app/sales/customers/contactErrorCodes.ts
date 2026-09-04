// PARTY-1:联系人那条路上的具名拒绝 → 双语句子。
// 形状逐字取自 expenseErrorCodes / equipmentErrorCodes(本仓库已有八处同形)。
//
// 【这张表是【逐条从函数体数出来的】,不是凭印象列的】重数一遍(把 CODES 换成
// 下面那几个码的交替式,注意【不要】把带引号的正则原样抄进注释 ——
// check-i18n 按单引号配对切这个 Set,一个落单的单引号会让它把半条注释读成一个键):
//   grep -rhoE "RAISE EXCEPTION .(CODES)" db/functions/save_counterparty_contact.sql
import { getTranslations } from '@/lib/i18n/server'

const CONTACT_ERROR_CODES = new Set([
    'CONTACT_NOT_FOUND',
    'CONTACT_DELETED',
    'CONTACT_OWNER_REQUIRED',
    'CONTACT_NAME_REQUIRED',
    'CONTACT_UNREACHABLE',
    'CUSTOMER_NOT_FOUND',
    'SUPPLIER_NOT_FOUND',
    'PERMISSION_DENIED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeContactError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)
    if (!match || !CONTACT_ERROR_CODES.has(match[1])) {
        return raw // 真正的非编码错误 —— 原样呈上,不要吞掉
    }
    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    }
    return (await getTranslations())('contacts.errors.' + code, params)
}
