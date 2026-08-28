import { getTranslations } from '@/lib/i18n/server'

// WHT-1:预提税那一族抛出的错误码(端口自 expenseErrorCodes.ts)。
//
// ★【这份名单是从【函数体】逐条数出来的,不是从"撞到过哪几条"数的】★
// 生成它的那条命令留在这里,因为下一个加拒绝的人要用同一条重数一遍:
//
//     grep -rhoE "RAISE EXCEPTION '(WHT_[A-Z_]+)" db/functions/*.sql db/tables/*.sql \
//       | sed "s/RAISE EXCEPTION '//" | sort -u
//
// 它们从六处冒出来:record_expense(裁定)、record_payment(代扣与两条范围外的
// 按名拒)、remit_wht(汇款)、wht_rate_for(税率解析)、以及 wht_remittances 的
// 不可变守卫。一条打到人脸上的机器码,是这个仓库反复付账的那个缺陷
// (docs/machine-text-reaching-humans.md),所以宁可多列,不可漏列。
//
// 【为什么不并进 financeErrorCodes】那一套读 finance.errors 命名空间,而预提税
// 的文案在 wht.errors。两套各自独立,与 expense.errors 的处置逐字相同 ——
// 见 expenseErrorCodes.ts 抬头。
const WHT_ERROR_CODES = new Set([
    // ── record_expense:裁定 ────────────────────────────────────────────────
    'WHT_PAYEE_NOT_A_SUPPLIER',
    'WHT_RESIDENCE_NOT_STATED',
    'WHT_PAYEE_IS_RESIDENT',
    'WHT_ON_PAID_EXPENSE_UNSUPPORTED',
    'WHT_TREATY_REF_WITHOUT_RATE',
    'WHT_TREATY_RATE_INVALID',
    'WHT_TREATY_RATE_ABOVE_STATUTORY',
    'WHT_TREATY_REF_REQUIRED',
    'WHT_NATURE_REQUIRED',
    // ── record_payment:代扣,以及范围外的两条 ─────────────────────────────
    'WHT_PREPAYMENT_NOT_SUPPORTED',
    'WHT_FREIGHT_NOT_SUPPORTED',
    'WHT_UNALLOCATED_PAYMENT_UNSUPPORTED',
    // ── remit_wht:汇款 ────────────────────────────────────────────────────
    'WHT_PERIOD_REQUIRED',
    'WHT_REMIT_DATE_REQUIRED',
    'WHT_REMIT_DATE_BEFORE_PERIOD',
    'WHT_FILED_REFERENCE_REQUIRED',
    'WHT_REMIT_BANK_NOT_BASE',
    'WHT_NOTHING_TO_REMIT',
    // ── wht_rate_for:税率解析(与 tax_rate_for / fx_rate_for 同一条规矩)──
    'WHT_NATURE_UNKNOWN',
    'WHT_NATURE_INACTIVE',
    'WHT_DATE_REQUIRED',
    'WHT_RATE_NOT_FOUND',
    // ── wht_remittances 的不可变守卫 ───────────────────────────────────────
    'WHT_REMITTANCE_IMMUTABLE',
    // ── 从底下冒上来的既有码:汇款走的是普通过账路径,所以期间锁照常拦 ────
    'PERIOD_LOCKED',
    'BANK_INVALID',
    'PERMISSION_DENIED',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeExpenseError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeWhtError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !WHT_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('wht.errors.' + code, params)
}
