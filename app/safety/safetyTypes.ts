// MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q7 · Q10):事故登记簿的几组取值 → 消息键。
//   【真源在库里】check-i18n 现读每一组的源:之后的事实的种类与可更正的字段 = incident_updates.sql 的 CHECK,链接的依据 = incident_batches.sql 的
//   CHECK,期限的状态 = incident_current_all.sql 里那一句 CASE。下面的 as const 只是表单的选项顺序,不是翻译的真源。
//   事故种类的名字在字典里(incident_kinds.name_en / name_zh,按界面语言选一个)—— 不是消息键。

/** 更正表单上能更正的七个字段(与 incident_updates.field 的 CHECK 同一张清单) */
export const CORRECTABLE_FIELDS = ['kind_code', 'occurred_at', 'what_happened', 'immediate_action', 'responsible_name', 'duration_min', 'nea_reportable'] as const

export function updateKindKey(kind: string): string {
    return 'safety.updateKind.' + kind
}
export function fieldKey(field: string): string {
    return 'safety.field.' + field
}
export function basisKey(basis: string): string {
    return 'safety.basis.' + basis
}
export function deadlineStateKey(state: string): string {
    return 'safety.deadlineState.' + state
}

export function incidentHref(id: string): string {
    return `/safety/incidents/${id}`
}
export function batchHref(kind: string, id: string): string {
    return kind === 'inbound' ? `/inbound/${id}/edit` : `/output/${id}/edit`
}

// ── MES-7b-2(2026-10-16,MES-7b Step 0 Q13 · Q16):巡检与环境监测的几组取值 → 消息键 ─────────────────────────────────────
//   【真源在库里】check-i18n 现读每一组的源:一项的结果 = inspection_results.sql 的 CHECK,到期的状态 = inspection_template_due_all.sql 那一句 CASE,
//   判定 = environmental_result_rows.sql 那一句 CASE,限值的口径 = environmental_parameters.sql 的 CHECK。下面的 as const 只是表单的选项顺序。

/** 一项的结果(与 inspection_results.result 的 CHECK 同一张清单) */
export const INSPECTION_RESULTS = ['pass', 'fail', 'na'] as const

export function inspectionResultKey(result: string): string {
    return 'safety.inspectionResult.' + result
}
export function dueStateKey(state: string): string {
    return 'safety.dueState.' + state
}
export function judgementKey(judgement: string): string {
    return 'safety.judgement.' + judgement
}
export function limitBasisKey(basis: string): string {
    return 'safety.limitBasis.' + basis
}
export function inspectionHref(id: string): string {
    return `/safety/inspections/${id}`
}
export function templateHref(id: string): string {
    return `/safety/inspections/templates/${id}`
}
