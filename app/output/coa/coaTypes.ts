// app/output/coa/coaTypes.ts
// MES-6b-2(2026-10-15,MES-6b Step 0 Q10–Q13 · Q31,Tim):一张分析证书纸上的每一个值 —— 库(coa_assemble)组装一次、签发时冻进快照
//   (certificates_of_analysis.snapshot)。PDF、证书页、批次页的证书一块都读这一个形状;PDF 【只】从它渲染。
//   预览(coa_certificate_data)是同一份组装,外加 blockers(这一刻为什么还签发不了),而 certificate / issuer 为空。

export type CoaComposition = { substance: string; name: string; symbol: string | null; role: string | null; content_pct: number | string }
export type CoaIndicator = { code: string; name: string; unit: string | null; value: number | string }
export type CoaLimit = { parameter: string; name: string; unit: string | null; min_value: number | string | null; max_value: number | string | null }
export type CoaJudgement = {
    parameter: string; name: string; unit: string | null; value: number | string | null
    limit_min: number | string | null; limit_max: number | string | null; result: string; assay_code: string; judged_at: string
}

export type CoaSnapshot = {
    company: {
        legal_name: string | null; registration_no: string | null; address_lines: string | null
        city: string | null; postal_code: string | null; country: string | null
    } | null
    batch: {
        id: string; code: string; material_code: string | null; material_name: string | null
        quantity: number | string; unit: string | null; output_date: string | null
    }
    assay: {
        id: string; code: string; assay_date: string | null; lab_code: string | null; lab_name: string | null
        certificate_ref: string | null; sample_ref: string | null; result_party: string | null; weight_basis: string | null
        moisture_pct: number | string | null; is_final: boolean; basis: 'dispute' | 'settling_party' | 'ours'; dispute_id: string | null
    } | null
    composition: CoaComposition[]
    indicators: CoaIndicator[]
    chemistry: {
        certainty: string; certainty_name: string; inbound_leaves: number; leaves_single_known: number
        leaves_mixed: number; leaves_not_recorded: number; leaves_unknown_pending: number
    } | null
    sales_order: {
        id: string; code: string | null; customer_name: string | null; contract_code: string | null; contract_title: string | null
        quality_limit_basis: string | null; limits: CoaLimit[]; judgements: CoaJudgement[]
    } | null
    /** 签发时才有(预览里为 null) */
    certificate: { id: string; code: string; status: string; issued_at: string } | null
    /** 签发时才有:「Issued by <名字>, <职位>」(Q13) */
    issuer: { name: string; position: string } | null
    /** 只在预览里:此刻签发不了的每一句具名拒绝(coa_issue_blockers) */
    blockers?: string[]
}

/** 一张已签发证书的读面(coa_rows) */
export type CoaRow = {
    id: string; code: string; status: 'issued' | 'void'; output_batch_id: string; batch_code: string
    sales_order_id: string | null; sales_order_code: string | null; customer_name: string | null
    governing_assay_id: string; governing_assay_code: string; issued_at: string
    issued_by_name: string | null; issued_by_position: string | null
    void_reason: string | null; voided_at: string | null; replaced_by_coa_id: string | null; replaced_by_code: string | null
    has_bytes: boolean; open_request_label: string | null
}

export const COA_ROW_COLUMNS = 'id, code, status, output_batch_id, batch_code, sales_order_id, sales_order_code, customer_name, governing_assay_id, ' +
    'governing_assay_code, issued_at, issued_by_name, issued_by_position, void_reason, voided_at, replaced_by_coa_id, replaced_by_code, has_bytes, ' +
    'open_request_label'

/** 证书 PDF 的三副面孔:预览(水印,不是证书)· 签发件 · 已作废(仍印全部内容,外加作废横幅) */
export type CoaMode = 'preview' | 'issued' | 'void'

export const COA_BUCKET = 'coa-documents'
