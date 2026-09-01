// app/components/audit/auditTrailTypes.ts
// AUDIT-1:审计轨迹一行的形状 —— 屏幕与查询共用一份。
//
// 【event_kind / seam 两个联合类型是【真源的副本】,不是新定义的清单】
// 取值由 db/views/batch_audit_trail_all.sql 决定;scripts/check-i18n.mjs 会从那份
// 视图 SQL 现读后缀集合,并要求 messages/{en,zh}.ts 两边都有对应的键。
// 所以这里少写一个不会静默:i18n 体检当场红。

/** 二十支里的哪一支。与视图里的 event_kind 一一对应。 */
export type AuditEventKind =
    | 'receipt'
    | 'output_created'
    | 'movement'
    | 'price_change'
    | 'run_input'
    | 'run_output'
    | 'cost_allocation'
    | 'cost_entry_change'
    | 'sale'
    | 'sale_movement'
    | 'attribution'
    | 'reservation'
    | 'shipment'
    | 'stocktake_line'
    | 'report_issued'
    | 'approval'
    | 'work_order_change'
    | 'po_change'
    | 'so_change'
    | 'journal_entry'

/**
 * 【接缝】—— 轨迹跟不动的那一跳,逐行标出来(Tim 的 R3)。
 * 一条不标出接缝的轨迹,是一份看起来完整的假证据。
 */
export type AuditSeam =
    | 'no_purchase_order'
    | 'actor_unrecorded'
    | 'actor_unresolvable'
    | 'polymorphic_source'
    | 'reversed'
    | 'is_reversal'
    | 'run_voided'
    | 'has_masked_amount'
    | 'amount_restricted'
    | 'no_policy_admits'
    | 'no_cogs_entry'

export type AuditTrailRow = {
    batch_kind: 'inbound' | 'output'
    batch_id: string
    occurred_at: string
    business_date: string | null
    event_kind: AuditEventKind
    module_code: string
    /** false = 这一段读者【不能看内容】。行仍然在,内容换成具名「受限」。 */
    may_view: boolean
    actor_id: string | null
    actor_space: 'auth' | 'employee'
    source_table: string
    source_id: string | null
    source_code: string | null
    href: string | null
    detail: Record<string, unknown> | null
    seams: AuditSeam[]
}

/**
 * 【够不到批次的六张历史表】—— 渲染成一条【具名脚注】,不是省略。
 * 实测(2026-09-01):这六张在 schema 上没有任何一条路通向批次,
 * 把它们建成永远空的臂,屏幕上会读成"这里什么都没发生过" ——
 * 正是 AUD-1 那个错的好消息,故意重建一遍。所以点名,不建臂。
 */
export const UNREACHABLE_HISTORY_TABLES = [
    'quote_history',
    'task_history',
    'customer_credit_history',
    'employment_history',
    'fx_rate_history',
    'pricing_formula_history',
] as const
