import { getTranslations } from '@/lib/i18n/server'

// 采购与预付款相关 DB 函数(create_purchase_order / cancel_purchase_order /
// apply_payment_term_template / apply_prepayment,以及 record_payment 的 PO 预付分支)
// 抛出的错误码(端口自 paymentErrorCodes.ts)。
// 不在此集合内的,是真正的(未编码的)DB/约束错误,原样返回。
const PURCHASING_ERROR_CODES = new Set([
    'ORDER_DATE_REQUIRED',
    'FX_RATE_MISSING', 'FX_RATE_NOT_ACCEPTED',
    'SUPPLIER_NOT_FOUND', 'NO_LINES', 'MATERIAL_NOT_FOUND', 'LINE_QTY_INVALID',
    'FORMULA_NOT_FOUND', 'FORMULA_INACTIVE', 'TERMS_SEQ_INVALID', 'TERMS_PCT_EXCEEDS',
    'PO_NOT_FOUND', 'PO_CANCELLED', 'PO_HAS_RECEIPTS', 'TEMPLATE_NOT_FOUND',
    'PREPAY_EXCEEDS_ESTIMATE', 'PREPAY_INSUFFICIENT', 'EXCEEDS_OPEN',
    // EQP-1b-i:冲抵学会了币种,于是多了一个目的地与一条【真正需要换算】的拒绝
    'PREPAY_DESTINATION_INVALID', 'PREPAY_TWO_FOREIGN_CURRENCIES',
    'EXPENSE_NOT_FOUND', 'EXPENSE_NOT_POSTED', 'EXPENSE_NOT_PAYABLE',
    'EXPENSE_IS_REVERSAL_MIRROR',
    'SUPPLIER_MISMATCH', 'INBOUND_UNPRICED', 'AMOUNT_INVALID',
    // FIN-26:行价出处
    'PRICE_SOURCE_INVALID', 'PROVENANCE_REQUIRED',
    // FIN-29:模板定额腿的币种 —— 未声明 / 与单据不同,都拒(不换算)
    'TEMPLATE_CURRENCY_REQUIRED', 'TEMPLATE_CURRENCY_UNDECLARED', 'TEMPLATE_CURRENCY_MISMATCH',
    // FIN-27:下单即抄下结算条款(承诺时刻);副本不可改写
    'PRICING_TERMS_NOT_COMMITTED', 'PRICING_TERMS_ALREADY_COMMITTED',
    'PRICING_COMMITMENT_IMMUTABLE', 'COMMITMENT_TARGET_INVALID',
    'ALLOC_WRONG_PARTY', 'PO_LINE_MISMATCH',
    // cut 4c:收货联动与结束/重开
    'PO_NOT_RECEIVABLE', 'PO_ALREADY_CLOSED', 'PO_NOT_CLOSED',
    'CLOSE_NOTES_REQUIRED', 'REASON_REQUIRED',
    // EQP-1a:采购单装得下一台机器之后,新出现的四条具名拒绝
    'PO_LINE_KIND_INVALID', 'ASSET_NOT_FOUND',
    'PO_LINES_MIXED_KINDS', 'PO_LINE_EQUIPMENT_NOT_RECEIVABLE',
    // EQP-PAY-1:里程碑适用性与质保金
    'PO_TERM_EVENT_NOT_APPLICABLE', 'PO_TERM_KIND_UNKNOWN', 'TERMS_EVENT_UNKNOWN',
    'RETENTION_NOT_AN_EQUIPMENT_LINE', 'RETENTION_ANCHOR_HAS_NO_DATE',
    'RETENTION_NOT_FOUND', 'RETENTION_ALREADY_RELEASED', 'RETENTION_CLOCK_NOT_STARTED',
    'RETENTION_NOT_MATURE', 'RETENTION_RELEASE_AMOUNTS_REQUIRED',
    'RETENTION_RELEASE_AMOUNT_NEGATIVE', 'RETENTION_RELEASE_DOES_NOT_BALANCE',
    'RETENTION_WITHHOLDING_NEEDS_REASON',
    // EQP-1a-TAIL:设备行的数量与单位从【约定】变成【规则】
    'PO_LINE_EQUIPMENT_QTY', 'PO_LINE_EQUIPMENT_UNIT',
    // CMP-2:这两个码一直会从收货触发器抛出,却不在这张表里 —— 打到操作员脸上的
    // 是裸管道串。拒绝要点名(供应商、证书、过期日 / 采购单、审批状态),用人话。
    'SUPPLIER_QUALIFICATION_EXPIRED', 'PO_NOT_APPROVED',
    // RECV-SOURCE-1:一张收货必须说得出它从哪来 —— 与上两条同族:收货触发器
    // 抛出、操作员会撞见。SOURCE_PROVENANCE_* 走事后补说明那条路(edit 面板)。
    'RECEIPT_SOURCE_REQUIRED', 'SOURCE_REASON_EXPLANATION_REQUIRED',
    'SOURCE_PROVENANCE_REQUIRED', 'SOURCE_PROVENANCE_NOT_AT_INTAKE',
    'PO_HEADER_WITHOUT_LINE',

    'PO_CANCEL_REASON_REQUIRED',   // AUDEL-1b
    // EQP-1b-ii:报销过的采购单行删不得。设备行【没有收货】,所以既有的
    // PO_LINE_HAS_RECEIPTS 对它恒为假 —— 这一条是它那一半。
    'PO_LINE_HAS_EXPENSE',
    // EQP-1c-b(S4 的产出):这八条【一直会被抛出,却从来没有句子】——
    // 全部来自改单/作废那条路,而 Tim 的走查正好要走它。它们不是本模块引进的,
    // 是本刀的 S4 普查扫出来的既有缺口:打到操作员脸上的是裸管道串。
    // PO_LINE_HAS_RECEIPTS 尤其值得一提 —— 它是 EQP-1b-ii 那条已接好的
    // PO_LINE_HAS_EXPENSE 的【亲兄弟】,同一个守卫的另一半,却一直没有句子。
    'PO_NOT_AMENDABLE', 'PO_AMEND_REASON_REQUIRED', 'PO_LINE_REMOVE_NEEDS_ID',
    'PO_LINE_QUANTITY_INVALID', 'PO_LINE_BELOW_RECEIVED', 'PO_LINE_HAS_RECEIPTS',
    'PO_PLAN_FIXED_MISMATCH', 'PO_HAS_APPLIED_PREPAYMENTS',
    // EQP-1c-b(X1):冲抵日必填
    'RELEASE_DATE_REQUIRED',
    // SOD-1(S3 的产出):审批引擎【整支】都没有句子 —— APR-1/APR-2 建了引擎、
    // 建了拒绝,却一条都没接到消息文件上。这十二条是从【函数体】里逐条枚举出来的,
    // 不是从"我碰巧撞到过哪几条"。审批一旦打开,操作员撞见的就是这些码本身。
    'APPROVALS_NOT_ENABLED', 'PO_NOT_PENDING', 'SELF_APPROVAL_FORBIDDEN',
    'REJECT_REASON_REQUIRED', 'APPROVAL_NOT_AUTHORISED',
    'APPROVAL_LEVEL1_ROLE_NOT_SET', 'APPROVAL_LEVEL2_USER_NOT_SET',
    'APPROVAL_THRESHOLD_NOT_SET', 'APPROVAL_AMOUNT_REQUIRED', 'APPROVAL_LEVEL_INVALID',
    'APPROVAL_SUBJECT_NOT_FOUND', 'APPROVAL_SUBJECT_TYPE_UNKNOWN',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeFinanceError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePurchasingError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PURCHASING_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('purchasing.errors.' + code, params)
}
