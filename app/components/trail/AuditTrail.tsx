// app/components/trail/AuditTrail.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1a · 一页底部的"Audit trail"(Tim 的 Q2–Q6 · Q27 · Q29)—— 服务端取数,造好句子再交给版式
// ════════════════════════════════════════════════════════════════════════════
// 【读法】record_trail(主语, id, 条数)—— 页面只说主语,不说表名(Q5)。拒绝是【具名的】:
//   TRAIL_NOT_PERMITTED / TRAIL_SUBJECT_UNKNOWN 在这一段里画成一句拒绝(一枚 Restricted 的意思),
//   【不是】一段空的审计记录 —— 空列表读起来是"什么都没发生过"。别的错误一律抛出(mustRows 同一条:失败不是空集)。
// 【英文专用】整段(标题、列头、每一句)都是英文,界面是中文时也一样(Q7)。
// 【分页】先 20 条;"Show older entries"把 ?trail= 加 20,整页重画并落回这一段(Q29)。
// 【数据只到服务端为止】给客户端的是造好的句子(Entry[]),不是原始行 —— 表名、主键、影像不进页面负载。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { Refusal } from '@/app/components/ui/refusal'
import { TRAIL_TEXT } from '@/lib/trail/text'
import { trailDict, TRAIL_LOG_BEGAN_AT } from '@/lib/trail/dict'
import { buildEntries, fill, fromRecordTrail, type Json } from '@/lib/trail/render'
import { formatTrailStamp } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import AuditTrailList, { OlderEntriesLink } from './AuditTrailList'

export type TrailSubject = 'purchase_order' | 'processing_run' | 'role' | 'inbound_batch' | 'output_batch' | 'work_order'
    | 'stocktake' | 'equipment' | 'shift_handover' | 'warehouse_request'
    | 'quote' | 'sales_order' | 'shipment' | 'customer' | 'commission_agreement' | 'supplier' | 'container' | 'forwarder'
    | 'lane' | 'port' | 'company_licence'
    | 'material' | 'storage_location' | 'metal_price' | 'pricing_formula' | 'task'
    | 'processing_settings' | 'pricing_settings' | 'receiving_settings'
    | 'journal_entry' | 'invoice' | 'credit_note' | 'payment' | 'payment_request' | 'expense' | 'payable'
    | 'sale' | 'freight' | 'fixed_asset' | 'bank_statement' | 'gst_period' | 'fx_rate' | 'management_pack' | 'contract'
    | 'finance_lock' | 'finance_gst' | 'company_profile' | 'year_close' | 'journal_request' | 'expense_claim' | 'my_expense_claim'
    | 'bank_transfer' | 'wht_remittance' | 'cash_forecast' | 'cash_forecast_line' | 'bank_import_profile'
    | 'account' | 'approval_policy' | 'employee' | 'department' | 'training_record' | 'import_batch'
    | 'dictionary_substances' | 'dictionary_battery_chemistries' | 'dictionary_material_kinds' | 'dictionary_inbound_safety_states'
    | 'dictionary_laboratories' | 'dictionary_inbound_source_reasons'
    | 'leave_request' | 'my_leave_request' | 'leave_grant' | 'leave_types' | 'public_holidays' | 'medical_claim' | 'my_medical_claim'
    | 'overtime_batch' | 'attendance_period'
    | 'payroll_period' | 'performance_review' | 'my_review' | 'review_cycle' | 'review_rating_scale' | 'kpi_entry'
    | 'device' | 'ingest_settings'

/** 主语的根表 —— 只用来从根行的"今天的样子"里取币种;与 db/functions/trail_subjects.sql 同一份(check-trail-wording 比对)。 */
export const TRAIL_SUBJECT_ROOTS: Record<TrailSubject, string> = {
    purchase_order: 'purchase_orders',
    processing_run: 'processing_runs',
    role: 'roles',
    inbound_batch: 'inbound_batches',
    output_batch: 'output_batches',
    work_order: 'work_orders',
    stocktake: 'stocktakes',
    equipment: 'fixed_assets',
    shift_handover: 'shift_handovers',
    warehouse_request: 'warehouse_requests',
    // AUDIT-TRAIL-1b-2
    quote: 'quotes',
    sales_order: 'sales_orders',
    shipment: 'shipments',
    customer: 'customers',
    commission_agreement: 'commission_agreements',
    supplier: 'suppliers',
    container: 'containers',
    forwarder: 'suppliers',
    lane: 'lanes',
    port: 'ports',
    company_licence: 'company_compliance',
    // AUDIT-TRAIL-1b-3
    material: 'materials',
    storage_location: 'storage_locations',
    metal_price: 'metal_prices',
    pricing_formula: 'pricing_formulas',
    task: 'tasks',
    processing_settings: 'processing_settings',
    pricing_settings: 'pricing_settings',
    receiving_settings: 'receiving_settings',
    // AUDIT-TRAIL-1c-1
    journal_entry: 'journal_entries',
    invoice: 'invoices',
    credit_note: 'credit_notes',
    payment: 'payments',
    payment_request: 'payment_requests',
    expense: 'expenses',
    payable: 'inbound_batches',
    // AUDIT-TRAIL-1c-2
    sale: 'sales_records',
    freight: 'freight_documents',
    fixed_asset: 'fixed_assets',
    bank_statement: 'bank_statements',
    gst_period: 'gst_periods',
    fx_rate: 'fx_rates',
    management_pack: 'management_packs',
    contract: 'contracts',
    // AUDIT-TRAIL-1c-3
    finance_lock: 'finance_settings',
    finance_gst: 'finance_settings',
    company_profile: 'company_profile',
    year_close: 'year_closes',
    journal_request: 'journal_requests',
    expense_claim: 'expense_claims',
    my_expense_claim: 'expense_claims',
    bank_transfer: 'bank_transfers',
    wht_remittance: 'wht_remittances',
    cash_forecast: 'cash_forecasts',
    cash_forecast_line: 'cash_forecast_lines',
    bank_import_profile: 'bank_import_profiles',
    // AUDIT-TRAIL-1d-1(account 的根在 auth —— M9;六本字典是集合 —— M11,页面交 'all')
    account: 'auth.users',
    approval_policy: 'finance_settings',
    employee: 'employees',
    department: 'departments',
    training_record: 'training_records',
    import_batch: 'import_batches',
    dictionary_substances: 'substances',
    dictionary_battery_chemistries: 'battery_chemistries',
    dictionary_material_kinds: 'material_kinds',
    dictionary_inbound_safety_states: 'inbound_safety_states',
    dictionary_laboratories: 'laboratories',
    dictionary_inbound_source_reasons: 'inbound_source_reasons',
    // AUDIT-TRAIL-1d-2(假别与公共假期是 M11 集合,页面交 'all';my_* 是 /me 上本人那几张 —— M8)
    leave_request: 'leave_requests',
    my_leave_request: 'leave_requests',
    leave_grant: 'leave_grants',
    leave_types: 'leave_types',
    public_holidays: 'public_holidays',
    medical_claim: 'medical_claims',
    my_medical_claim: 'medical_claims',
    overtime_batch: 'overtime_batches',
    attendance_period: 'attendance_periods',
    // AUDIT-TRAIL-1d-3(my_review 是 /my-reviews 上审核人那一份 —— M8 + M12;评分刻度是 M11 集合,页面交 'all';
    //   轮次与 KPI 条目住在清单页上的那一块)
    payroll_period: 'payroll_periods',
    performance_review: 'performance_reviews',
    my_review: 'performance_reviews',
    review_cycle: 'review_cycles',
    review_rating_scale: 'review_rating_scale',
    kpi_entry: 'kpi_entries',
    // MES-1
    device: 'devices',
    ingest_settings: 'ingest_settings',
}

export const PAGE = 20

/** 页面把 searchParams.trail 交进来;不合法的一律当 20 */
export function trailCount(raw: string | string[] | undefined): number {
    const n = Number(Array.isArray(raw) ? raw[0] : raw)
    return Number.isInteger(n) && n >= PAGE && n <= 500 ? n : PAGE
}

// AUDIT-TRAIL-1c-3:一页上不止一段时(/finance/settings 的锁期与 GST 两块面板、/finance/close 的锁期与年结),每一段一个自己的
//   anchor —— section 的 id 与"Show older entries"落回的地方。同一页的几段共用 ?trail=(点一段的"更早"几段一起多读 20 条,
//   落回点的那一段)。不传就是 'audit-trail',与以前逐字相同。
// compact:一张卡片 / 一行里的那一块(人工分录申请、报销单 —— Q17 · Q20):折起来(<details>),标题与说明不画,
//   分页链接落回那一块;section 照样带 data-audit-trail,冒烟与探针认得出它。
export default async function AuditTrail({ subject, id, show, anchor = 'audit-trail', compact = false }: {
    subject: TrailSubject; id: string; show: number; anchor?: string; compact?: boolean
}) {
    const supabase = await createClient()
    const res = await supabase.rpc('record_trail', { p_subject: subject, p_id: id, p_entries: show })
    const heading = compact ? null : (
        <>
            <h2 className="mb-1">{TRAIL_TEXT['section.title']}</h2>
            <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['section.intro']}</p>
        </>
    )
    const frame = (state: string, body: React.ReactNode) => compact ? (
        <details id={anchor} className="mt-3 border-t pt-2">
            <summary className="cursor-pointer text-xs text-[color:var(--brand-muted-text)]">{TRAIL_TEXT['rowTrail.summary']}</summary>
            <section data-audit-trail={state} className="mt-2">{body}</section>
        </details>
    ) : (
        <section id={anchor} data-audit-trail={state} className="mt-8 border-t pt-6">{heading}{body}</section>
    )
    if (res.error) {
        const code = res.error.message.split('|')[0]
        if (code === 'TRAIL_NOT_PERMITTED' || code === 'TRAIL_SUBJECT_UNKNOWN') {
            return frame('refused', (
                <p className="text-sm">
                    <Refusal>{TRAIL_TEXT.restricted}</Refusal>{' '}
                    {TRAIL_TEXT[code === 'TRAIL_NOT_PERMITTED' ? 'refusal.notPermitted' : 'refusal.unknown']}
                </p>
            ))
        }
        throw new Error(`record_trail(${subject}) failed: ${res.error.message}`)
    }
    // 两种具名拒绝上面已经接住;走到这里的只能是成功(mustRows 对别的错误照样抛)
    const rows = mustRows(res, `record_trail(${subject})`)
    const dict = trailDict(await getBaseCurrency())
    const root = rows.find((r) => r.table_name === TRAIL_SUBJECT_ROOTS[subject] && r.ctx)
    const ctx = (root?.ctx ?? null) as { currency?: Json } | null
    const currency = typeof ctx?.currency === 'string' ? ctx.currency : null
    const entries = buildEntries(dict, rows.map((r) => fromRecordTrail(r as Parameters<typeof fromRecordTrail>[0])), { currency, subject, recordId: id })
    const more = rows.some((r) => r.more)
    return frame(entries.length ? 'entries' : 'empty', (
        <>
            {entries.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{TRAIL_TEXT.noEntries}</p>
            ) : (
                <AuditTrailList entries={entries} divider={fill(TRAIL_TEXT.divider, { date: formatTrailStamp(TRAIL_LOG_BEGAN_AT) })} />
            )}
            {more && <OlderEntriesLink href={`?trail=${show + PAGE}#${anchor}`} />}
        </>
    ))
}
