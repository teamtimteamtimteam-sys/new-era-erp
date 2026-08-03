// app/hr/reviews/reviewShared.ts
// 评估的规范值与两侧列表(/hr/reviews 与 /my-reviews)共用的小逻辑。
// 状态与类型的集合与 DB 的 CHECK 一一对应(同 app/hr/options.ts 的约定)。
export const REVIEW_STATUSES = [
    'draft',
    'self_review',
    'submitted',
    'approved',
    'acknowledged',
    'void',
] as const
export type ReviewStatus = (typeof REVIEW_STATUSES)[number]

export const REVIEW_TYPES = ['probation', 'annual'] as const

// performance_reviews_masked 里列表与文档页都要的列。
// 【薪酬列只在持 data.view_pay(或本人)时非空】—— 遮蔽在视图里,这里只是形状。
export type ReviewRow = {
    id: string
    employee_id: string
    review_type: string
    cycle_id: string | null
    period_start: string
    period_end: string
    reviewer_employee_id: string | null
    status: string
    rating_code: string | null
    summary_text: string | null
    self_assessment_text: string | null
    probation_outcome: string | null
    new_monthly_salary: number | null
    salary_effective_date: string | null
    submitted_at: string | null
    submitted_by: string | null
    approved_at: string | null
    approved_by: string | null
    acknowledged_at: string | null
    void_reason: string | null
    voided_at: string | null
    self_assessment_submitted_at: string | null
    created_at: string
    updated_at: string
}

export const REVIEW_COLUMNS =
    'id, employee_id, review_type, cycle_id, period_start, period_end, reviewer_employee_id, ' +
    'status, rating_code, summary_text, self_assessment_text, probation_outcome, ' +
    'new_monthly_salary, salary_effective_date, submitted_at, submitted_by, approved_at, ' +
    'approved_by, acknowledged_at, void_reason, voided_at, self_assessment_submitted_at, ' +
    'created_at, updated_at'

export type GoalRow = {
    id: string
    review_id: string
    sequence: number
    objective_text: string
    target_value: number | null
    unit: string | null
    actual_value: number | null
    employee_result_text: string | null
    reviewer_assessment_text: string | null
}

export function statusPillClass(status: string): string {
    switch (status) {
        case 'draft':
            return 'bg-gray-100 text-gray-700'
        case 'self_review':
            return 'bg-blue-100 text-blue-800'
        case 'submitted':
            return 'bg-amber-100 text-amber-800'
        case 'approved':
            return 'bg-green-100 text-green-800'
        case 'acknowledged':
            return 'bg-green-200 text-green-900'
        default: // void
            return 'bg-red-100 text-red-800'
    }
}

// 进入当前状态的时点。submitted/approved/acknowledged/void 有确切的时间戳;
// draft 没有回头路,created_at 就是进入时点;self_review 没有记录进入时点 ——
// 自评已定稿就取定稿时点(此后是在【等评估人】),否则退而取 updated_at(近似)。
export function stateEnteredAt(r: ReviewRow): string {
    switch (r.status) {
        case 'submitted':
            return r.submitted_at ?? r.updated_at
        case 'approved':
            return r.approved_at ?? r.updated_at
        case 'acknowledged':
            return r.acknowledged_at ?? r.updated_at
        case 'void':
            return r.voided_at ?? r.updated_at
        case 'self_review':
            return r.self_assessment_submitted_at ?? r.updated_at
        default: // draft
            return r.created_at
    }
}

export function daysInState(r: ReviewRow): number {
    const entered = new Date(stateEnteredAt(r)).getTime()
    return Math.max(0, Math.floor((Date.now() - entered) / 86400000))
}
