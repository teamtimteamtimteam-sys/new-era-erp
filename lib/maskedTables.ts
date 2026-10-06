// lib/maskedTables.ts
// 【生成的文件,不要手改】由 scripts/gen-masked-tables.mjs 从 lib/database.types.ts 生成,
// 由 scripts/check-masked-reads.mjs 校验是否同步(不同步则构建失败)。
//
// 一张表出现在这里,意思是它【有列被从 authenticated 手里收回】—— 也就是它带着
// 受限数据(薪资 / 身份 / 银行 / 价格 / 评估正文之类)。这是数据库自己的说法,
// 不是另一张需要有人记得更新的清单。
//
// 草稿留存据此决定【不为哪些表留草稿】:见 lib/useFormDraft.ts。
export const MASKED_TABLES: ReadonlySet<string> = new Set([
    'approval_log',
    'company_profile',
    'employees',
    'employment_history',
    'gateway_keys',
    'inbound_batches',
    'invoice_lines',
    'invoices',
    'journal_lines',
    'journal_requests',
    'leave_requests',
    'medical_claims',
    'payment_term_template_lines',
    'payroll_lines',
    'payroll_periods',
    'payroll_requests',
    'performance_reviews',
    'prepayment_applications',
    'price_history',
    'pricing_formula_history',
    'pricing_formula_metals',
    'pricing_formulas',
    'pricing_term_commitment_metals',
    'pricing_term_commitments',
    'processing_cost_entries',
    'processing_cost_entry_history',
    'processing_outputs',
    'processing_runs',
    'purchase_order_history',
    'purchase_order_line_retentions',
    'purchase_order_lines',
    'purchase_order_payment_terms',
    'purchase_orders',
    'sales_records',
    'warehouse_requests',
])
