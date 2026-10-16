// MES-8a:供应商评分卡的形状 —— 库里 supplier_scorecard_measures / _preview 与 supplier_score_settings 吐的那几份 jsonb,原样。
// 计分项的名字与库里 supplier_scorecard_measure_keys() 逐字同一组(check-i18n 从这里读,scorecards.measure.<键> 每一个都要有一句)。
export const SCORED_MEASURES = [
    'short_lines', 'over_lines', 'ncr_open', 'ncr_accept', 'ncr_accept_with_penalty', 'ncr_reject', 'ncr_rework',
    'ncr_downgrade', 'disputes', 'discharge_mismatches', 'certificate_lapse_days',
] as const
export type ScoredMeasure = typeof SCORED_MEASURES[number]

export type MeasureCell = { count: number | null; compared?: number; not_compared?: number }

export type Measures = {
    supplier_id: string
    supplier_code: string
    window_from: string
    window_to: string
    receipts: number
    receipts_without_po_line: number
    scored: Record<ScoredMeasure, MeasureCell>
    shown: {
        grade_breaches: { count: number; scored: false; caveat: string }
        disputes_withdrawn: { count: number; scored: false }
    }
}

export type GradeLine = { grade: string; max_score: number | null }
export type GradeCap = { prepayment_cap_pct: number | null; sampling_level: string | null }

export type ScoreSettings = {
    weights: Record<ScoredMeasure, number> | null
    grade_lines: GradeLine[] | null
    review_window_days: number | null
    grade_caps: Record<string, GradeCap> | null
}

export type ScorecardPreview = {
    measures: Measures
    weights: Record<ScoredMeasure, number> | null
    grade_lines: GradeLine[] | null
    grade_caps: Record<string, GradeCap> | null
    score: number | null
    grade: string | null
    not_graded_reason: string | null
    grade_advice: GradeCap | null
}

export type ReviewRow = {
    id: string
    seq: number
    window_from: string
    window_to: string
    measures: Measures
    weights: Record<ScoredMeasure, number> | null
    grade_lines: GradeLine[] | null
    grade_caps: Record<string, GradeCap> | null
    score: number | null
    grade: string | null
    not_graded_reason: string | null
    note: string | null
    corrects_review_id: string | null
    correction_reason: string | null
    recorded_at: string
}

/** 库里 supplier_grade_advice 的返回 —— 采购单表单与收货页读它。 */
export type GradeAdvice = {
    reviewed: boolean
    graded: boolean
    review_id: string | null
    reviewed_at?: string
    window_from?: string
    window_to?: string
    grade: string | null
    not_graded_reason?: string | null
    prepayment_cap_pct: number | null
    sampling_level: string | null
    on_order_pct: number | null
    on_order_not_computable?: boolean
    warnings: { code: 'PREPAYMENT_ABOVE_GRADE_CAP'; grade: string; cap_pct: number; on_order_pct: number; review_id: string }[]
}
