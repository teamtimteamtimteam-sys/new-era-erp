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
