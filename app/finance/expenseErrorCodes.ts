import { getTranslations } from '@/lib/i18n/server'

// record_expense / reverse_expense 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 文案统一放 expense.errors(FX_RATE_REQUIRED / PERIOD_LOCKED 等与 finance.errors
// 同码但独立成套,避免跨命名空间引用)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const EXPENSE_ERROR_CODES = new Set([
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'ACCOUNT_NOT_FOUND', 'ACCOUNT_INACTIVE', 'ACCOUNT_NOT_EXPENSE',
    'AMOUNT_INVALID', 'FX_RATE_REQUIRED', 'PAYMENT_STATUS_INVALID',
    'BANK_INVALID', 'SUPPLIER_REQUIRED_FOR_UNPAID', 'SUPPLIER_NOT_FOUND',
    // PAYEE-1a:往来对象二选一(供应商 或 员工)。
    // SUPPLIER_REQUIRED_FOR_UNPAID 【数据库不再抛它】—— 它留在这里,是因为
    // 开支表单自己还有一道前置检查在用那句文案(那张表单目前只提供供应商,
    // 员工选项是 1b)。DB 侧的三个新码在这里,否则屏幕上会出现机器码。
    'COUNTERPARTY_REQUIRED_FOR_UNPAID', 'COUNTERPARTY_AMBIGUOUS', 'EMPLOYEE_NOT_FOUND',
    'PERIOD_LOCKED', 'EXPENSE_NOT_FOUND', 'EXPENSE_ALREADY_REVERSED',
    // FIN-22:资本分支(record_expense)与冲销守卫(reverse_expense)
    'CAPITAL_REQUIRES_ASSET', 'ASSET_REQUIRES_CAPITAL_ACCOUNT',
    'ASSET_DESCRIPTION_REQUIRED', 'ASSET_LIFE_INVALID', 'ASSET_RESIDUAL_INVALID',
    'ASSET_IN_SERVICE_BEFORE_ACQUISITION', 'EXPENSE_HAS_ASSET',
    // EQP-1b-ii:支出挂上采购单行之后新出现的具名拒绝。
    // 三条单据守卫(PO_*)与 apply_prepayment 同码同义 —— 同一件事在两条路上
    // 说同一句话,不为了"这是费用侧"另起一套名字。
    'PO_LINE_NOT_FOUND', 'PO_NOT_FOUND', 'PO_CANCELLED', 'PO_NOT_APPROVED',
    'PO_LINE_NOT_EQUIPMENT',
    // D3 下半拆成三条,因为三种情形的【修法不同】
    'EXPENSE_NOT_CAPITAL', 'EXPENSE_CREATES_ASSET', 'EXPENSE_ASSET_MISMATCH',
    // 主体可缺席:paid 的费用单合法地没有供应商,那不是"不一致"
    'EXPENSE_SUPPLIER_NOT_STATED', 'SUPPLIER_MISMATCH',
    // D4:一条设备行只报销一次
    'PO_LINE_ALREADY_EXPENSED',
    // EQP-1b-iii:冲销一笔资本支出要把成本一起退回去,于是多两条。
    // ASSET_COST_LEDGER_DIVERGED 是【本不该发生】的那一条(表头与明细之和对不上),
    // 但它照样要有人话:一条只会在出事时出现的拒绝,恰恰最不该是一串机器码。
    'ASSET_IN_SERVICE_COST_LOCKED', 'ASSET_COST_LEDGER_DIVERGED',
    // EQP-1c-b(S4):record_expense 在日期为空时抛它,而它一直没有句子。
    'JE_LINE_INVALID',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeExpenseError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !EXPENSE_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('expense.errors.' + code, params)
}
