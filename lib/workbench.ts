// lib/workbench.ts
// ════════════════════════════════════════════════════════════════════════════
// SYSTEM-MAP-2(Tim 2026-10-26 裁定 2.4 (9) · (10),2026-10-27 Q1–Q7)· 工作台 › 待办
// ════════════════════════════════════════════════════════════════════════════
// 【数据只有一份】db/functions/waiting_for_me.sql —— 我批得了的每一种审批(waiting_decisions:CFO 级、1,000 分档、
//   四眼与自批例外都在库里判)、已批准等我付的付款申请、我的任务与考核(waiting_mine)、我没读过的通知。
//   首页那个数是同一条查询的行数(waiting_for_me_count)。本文件不判谁看得见什么,只负责【它去哪儿】与【它叫什么】。
// 【去处】每一行链到做决定的那一页(Tim 2.4 (9):"links to the page where the decision is made");
//   住在一张列表页顶上那一块的申请带锚点(#jr- · #wr- · #tr- · #adr- · #gfr- · #claim-),那一页的 <HashTarget> 把它滚进视野。
// 【批量】只在那一种的决定【今天已经支持批量】的地方(Tim C:不发明新的决定路径)——
//   approve+reject:手工凭证 · 仓库 · 条款 · 资产处置申请;只驳回:一般报销 · 过磅草稿(TABLE-FEATURES-3 的那几张)。
//   其余每一行链出去。
// ════════════════════════════════════════════════════════════════════════════
import { toYmd } from '@/lib/dates'

/** waiting_for_me().item_type 的全部取值 —— scripts/check-i18n.mjs 从这里读 workbench.type.* 的后缀集合。
 *  前 24 种 = db/functions/waiting_decisions.sql 的种类(fixture 295 数着它们);后四种 = waiting_mine 与通知。 */
export const TODO_TYPES = [
    'purchase_order', 'expense_claim', 'payment_request', 'payroll_request', 'receipt_price_request', 'invoice_request',
    'shipping_release', 'journal_request', 'warehouse_request', 'terms_request', 'asset_disposal_request', 'gst_filing_request',
    'salary_change_request', 'overtime_batch', 'performance_review', 'leave_request', 'medical_claim', 'ncr', 'work_order',
    'blending_plan', 'supplier', 'capture_draft', 'portal_certificate', 'payment_to_pay',
    'task', 'review_write', 'self_review', 'notification',
] as const
export type TodoType = (typeof TODO_TYPES)[number]

export type TodoKind = 'decision' | 'mine' | 'notification'

/** waiting_for_me() 的一行(lib/database.types.ts 的那一份,raised_by 是 trail_actor 的形状)。 */
export type WaitingRow = {
    kind: string
    item_type: string
    item_id: string
    parent_id: string | null
    doc_kind: string | null
    code: string | null
    subject: string | null
    raised_by: unknown
    waiting_since: string | null
    due_date: string | null
}

export function isTodoType(s: string): s is TodoType {
    return (TODO_TYPES as readonly string[]).includes(s)
}

/** 做这个决定的那一页。认不出种类 → null(不给链接,不猜一个 —— 提醒页 itemHref 同一条规矩)。 */
export function todoHref(r: Pick<WaitingRow, 'item_type' | 'item_id' | 'parent_id' | 'doc_kind'>): string | null {
    const id = r.item_id
    const parent = r.parent_id
    switch (r.item_type) {
        case 'purchase_order': return `/purchasing/orders/${id}`
        case 'expense_claim': return `/finance/claims#claim-${id}`
        case 'payment_request': return `/finance/payment-requests/${id}`
        case 'payment_to_pay': return `/finance/payment-requests/${id}`
        case 'payroll_request': return parent ? `/hr/payroll/${parent}` : null
        case 'receipt_price_request': return parent ? `/inbound/${parent}/edit` : null
        case 'invoice_request': return parent ? `/finance/invoices/${parent}` : null
        case 'shipping_release': return parent ? `/sales/orders/${parent}` : null
        case 'journal_request': return `/finance/journal#jr-${id}`
        case 'warehouse_request': return `/inventory#wr-${id}`
        case 'terms_request':
            if (r.doc_kind === 'contract' && parent) return `/contracts/${parent}#tr-${id}`
            if (r.doc_kind === 'formula' && parent) return `/tools/pricing/formulas/${parent}/edit#tr-${id}`
            return `/tools/pricing/formulas#tr-${id}`
        case 'asset_disposal_request': return `/finance/assets#adr-${id}`
        case 'gst_filing_request': return parent ? `/finance/gst/${parent}#gfr-${id}` : null
        case 'salary_change_request': return parent ? `/hr/employees/${parent}#salary-requests` : null
        case 'overtime_batch': return `/hr/overtime/${id}`
        case 'performance_review': return `/hr/reviews/${id}`
        case 'leave_request': return `/hr/leave/${id}`
        case 'medical_claim': return `/hr/claims/${id}`
        case 'ncr': return `/quality/ncr/${id}`
        case 'work_order': return `/operation/orders/${id}`
        case 'blending_plan': return `/operation/blending/${id}`
        case 'supplier': return `/suppliers/${id}/edit`
        case 'capture_draft': return '/operation/capture'
        case 'portal_certificate': return parent ? `/suppliers/${parent}/edit` : null
        case 'task': return `/tools/tasks/${id}`
        case 'review_write': return `/my-reviews/${id}`
        case 'self_review': return '/me'
        case 'notification': return '/notifications'
        default: return null
    }
}

/** 这一种的决定今天有没有批量(TABLE-FEATURES-3)。'both' = 批准与驳回;'reject' = 只驳回;null = 链出去。 */
export function bulkMode(type: string): 'both' | 'reject' | null {
    switch (type) {
        case 'journal_request':
        case 'warehouse_request':
        case 'terms_request':
        case 'asset_disposal_request':
            return 'both'
        case 'expense_claim':
        case 'capture_draft':
            return 'reject'
        default:
            return null
    }
}

/** 等了多少天:从 waiting_since 到今天(新加坡日期)。没有起点 → null。 */
export function daysWaited(since: string | null, todaySg: string): number | null {
    if (!since) return null
    // toYmd 按业务时区(新加坡)取那一天 —— 与 businessToday() 同一个时区,于是两个日历日相减
    const sinceSg = toYmd(since)
    if (!sinceSg) return null
    const ms = Date.parse(`${todaySg}T00:00:00Z`) - Date.parse(`${sinceSg}T00:00:00Z`)
    return Math.max(0, Math.round(ms / 86_400_000))
}
