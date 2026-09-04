// COMM-1:佣金那条路上的具名拒绝 → 双语句子。
// 形状逐字取自 contactErrorCodes / expenseErrorCodes(本仓库已有九处同形)。
//
// ★★【这张表是【逐条从函数体与约束里数出来的】,不是凭印象列的】★★
//   本刀【没有 RPC】—— 写入走的是直连 + RLS,所以拒绝有【两种到达方式】,
//   而两种都必须有句子,否则它们会以裸错误的形态到达浏览器
//   (EQP-2d 为设备三张表的 16 条约束记过同一件事,见 docs/known-issues.md)。
//
//   ① 守卫函数抛的具名异常 —— 逐条数自函数体:
//        grep -o "RAISE EXCEPTION '[A-Z_]*" db/functions/guard_commission_agreement_agent.sql
//      → COMMISSION_AGENT_NOT_SERVICE_VENDOR
//
//   ② 表自己的约束 —— 逐条数自 db/tables/commission_agreements.sql:
//        commission_agreements_basis_fields     (CHECK,口径与格子对不上)
//        commission_agreements_validity_order   (CHECK,止日早于起日)
//        recognition_trigger 的 NOT NULL        (那一列【故意】没有默认值)
//      三条都由 PostgreSQL 按【约束名】报出来,所以这里按名字认,
//      而不是去猜错误文本 —— 约束名是我们自己起的,错误文本不是。
import { getTranslations } from '@/lib/i18n/server'

const COMMISSION_ERROR_CODES = new Set([
    'COMMISSION_AGENT_NOT_SERVICE_VENDOR',
    'COMMISSION_TRIGGER_REQUIRED',
    'COMMISSION_BASIS_FIELDS',
    'COMMISSION_VALIDITY_ORDER',
    // ③ RLS 的拒绝。**它不是任何函数体抛的**,是策略挡下来的 ——
    //    写这张表要 module.suppliers.edit,而只有 view 的人会撞上它。
    //    PostgreSQL 报的是 42501 + "row-level security policy",一句机器话;
    //    不接住它,它就以裸错误的形态到达浏览器(EQP-2d 记过同一件事)。
    'COMMISSION_NOT_PERMITTED',
    // ④ 认证服务够不着 —— **不是**"没登录"。SESSION-1 的实测表把这两类分开了,
    //    而写下一行【作者不明】的协议比拒绝它坏:created_by 是审计事实。
    'COMMISSION_AUTH_UNAVAILABLE',
    // 有效期两端也是服务端独立拒空的(表上是 NOT NULL,这里先说人话)。
    'COMMISSION_VALIDITY_REQUIRED',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

// 约束名 / 列名 → 本刀的具名码。
// 【为什么要这一层】一条 CHECK 违反到达时,message 里是约束名,不是一个码;
// 把约束名直接印给用户等于把库的内部名字当成一句话用。
const CONSTRAINT_TO_CODE: Record<string, string> = {
    commission_agreements_basis_fields: 'COMMISSION_BASIS_FIELDS',
    commission_agreements_validity_order: 'COMMISSION_VALIDITY_ORDER',
}

export async function localizeCommissionError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    // ② 先认约束名 —— 它比下面那个正则更具体,所以排在前面。
    for (const [constraint, code] of Object.entries(CONSTRAINT_TO_CODE)) {
        if (raw.includes(constraint)) return t('commissions.errors.' + code)
    }
    // recognition_trigger 的 NOT NULL:PostgreSQL 报的是列名 + null value。
    // 【这一条单独认,因为它正是本表最要紧的那一列】—— 没有默认值是刻意的,
    // 所以它被漏填时必须说人话,而不是 'null value in column ...'。
    if (raw.includes('recognition_trigger') && /null value|not-null/i.test(raw)) {
        return t('commissions.errors.COMMISSION_TRIGGER_REQUIRED')
    }

    // ③ RLS:按 SQLSTATE 的措辞认,而不是猜某一句文案。
    if (/row-level security|42501/i.test(raw)) {
        return t('commissions.errors.COMMISSION_NOT_PERMITTED')
    }

    // ① 再认具名异常
    const match = raw.match(CODE_RE)
    if (!match || !COMMISSION_ERROR_CODES.has(match[1])) {
        return raw // 真正的非编码错误 —— 原样呈上,不要吞掉
    }
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => { params[String(i)] = v })
    }
    return t('commissions.errors.' + match[1], params)
}
