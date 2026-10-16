// app/compliance/packs/packTypes.ts
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14,Tim):合规包 payload 的形状 —— compliance_pack_data(月) 的返回值,
//   冻下来的那一份(compliance_packs.payload)与页面上的实时预览是同一个形状(一份实现,两个调用方)。
//   这里只描述字段,不算任何东西;改字段要与 db/functions/compliance_pack_data.sql 一起改。

export type PackCompany = {
    legal_name: string; registration_no: string | null; address_lines: string | null; city: string | null; postal_code: string | null
    country: string | null; phone: string | null; email: string | null; website: string | null
}
export type PackBalanceLine = {
    scope: 'plant' | 'operation'; operation_type_code: string | null; line: string; line_key: string | null; basis: string | null
    qty_kg: number; runs: number
}
export type PackRollforward = {
    unit: string; opening: number; received: number; produced: number; consumed: number; sold: number; written_off: number
    adjusted: number; voided: number; issued_to_maintenance: number; moved: number; closing: number
}
export type PackLicence = {
    cert_type_code: string; cert_no: string; issuing_body: string | null; scope: string | null
    valid_from: string; valid_until: string; approved_storage_limit_tonnes: number | null
}
export type PackCategory = {
    category_code: string; name_en: string; batches: number; tonnes: number; unconvertible_batches: number
    limit_tonnes: number | null; state: 'licence_not_in_force' | 'ceiling_not_set' | 'above_ceiling' | 'within_ceiling'
}
export type PackCeilingCheck = { outcome: string; category_code: string | null; checks: number }
export type PackIncident = {
    code: string; kind_code: string; kind_name_en: string | null; occurred_on: string; nea_reportable: boolean
    notified_on: string | null; report_submitted_on: string | null; report_deadline: string | null
    deadline_state: 'not_reportable' | 'submitted' | 'not_set' | 'cannot_compute' | 'computed'; closed_on: string | null
}
export type PackEnvResult = {
    parameter_code: string; parameter_name_en: string | null; sample_point: string; sampled_on: string; value: number; unit: string
    limit_value: number | null; limit_basis: string | null; judgement: 'exceeds' | 'within' | 'not_judged'
    incident_code: string | null; corrects: string | null; superseded: boolean
}
export type PackInspection = {
    code: string; template_code: string; template_name: string; area: string | null; inspected_on: string
    passed: number; failed: number; not_applicable: number; corrects: string | null; corrected_by: string | null
}
export type PackOpenFinding = {
    run_code: string; item: string | null; corrective_action: string; due_date: string | null; inspected_on: string; days_open_at_month_end: number
}
export type PackMasses = { input_kg: number; outputs: { form: string | null; qty_kg: number }[] }

export type CompliancePackPayload = {
    month: string; period_start: string; period_end: string; locked_before: string | null; month_locked: boolean
    system_start_date: string | null
    company: PackCompany | null
    processing_balance: PackBalanceLine[]
    stock_rollforward: PackRollforward[]
    licence: {
        in_force: PackLicence | null; on_hand_by_category: PackCategory[]; uncategorised_tonnes: number
        movements_without_business_date: number; ceiling_checks: PackCeilingCheck[]
    }
    incidents: PackIncident[]
    environmental: PackEnvResult[]
    inspections: { done: PackInspection[]; findings_open_at_month_end: PackOpenFinding[] }
    nea_return: { state: 'not_set' | 'set'; value_code: 'V26'; format?: string; frequency?: string }
    eu_efficiency: { state: 'not_set' | 'set'; value_code: 'V27'; method?: string; targets?: string; masses: PackMasses; computed?: boolean }
}
