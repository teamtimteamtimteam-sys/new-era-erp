// MES-6a-1(2026-10-09,MES-6a Step 0 Q7–Q25):样品与化验争议的几组取值 → 消息键。
//   【真源在库里】check-i18n 现读每一组的源:种类 / 留样日来源 = samples.sql 的 CHECK,保管记录 = sample_events.sql 的 CHECK,
//   状态 = sample_rows.sql 第一句 CASE,争议状态 = assay_disputes.sql 的 CHECK,出具方 = assay_results.sql 的 CHECK,
//   仲裁费规则 = contract_settlement_terms.sql 的 CHECK。下面两张 as const 只是表单的选项顺序,不是翻译的真源。

/** 取样表单上的种类,按常用先后 */
export const SAMPLE_KINDS = ['ours', 'counterparty', 'umpire', 'retained', 'contamination'] as const
/** 保管记录表单上能记的四种(taken 只由取样写) */
export const SAMPLE_EVENT_KINDS = ['sent_to_lab', 'received_back', 'moved', 'disposed'] as const

/** 这一份样品此刻能记哪几种(与 record_sample_event 的顺序规矩同一句:拿在手上 → 送、挪、处置;在实验室 → 拿回、处置;处置之后什么都不能记)。
 *  只用来把选不了的那几项画成灰的 —— 拒绝仍由服务端按名给(SAMPLE_EVENT_NOT_ALLOWED)。 */
export function allowedEventKinds(state: string): readonly string[] {
    if (state === 'disposed') return []
    if (state === 'at_lab') return ['received_back', 'disposed']
    return ['sent_to_lab', 'moved', 'disposed']
}

export function sampleKindKey(kind: string): string {
    return 'quality.kind.' + kind
}
export function sampleStateKey(state: string): string {
    return 'quality.state.' + state
}
export function sampleEventKey(kind: string): string {
    return 'quality.event.' + kind
}
export function retentionSourceKey(source: string): string {
    return 'quality.retentionSource.' + source
}
export function disputeStatusKey(status: string): string {
    return 'quality.disputeStatus.' + status
}
export function resultPartyKey(party: string): string {
    return 'quality.party.' + party
}
export function feeRuleKey(rule: string): string {
    return 'quality.feeRule.' + rule
}

/** 一批的身份:`inbound:<uuid>` / `output:<uuid>` —— 新建样品与新建争议的 ?batch= 参数用同一个写法 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
export type BatchRef = { kind: 'inbound' | 'output'; id: string }
export function parseBatchRef(raw: string | string[] | undefined): BatchRef | null {
    const v = Array.isArray(raw) ? raw[0] : raw
    if (!v) return null
    const [kind, id] = v.split(':')
    if ((kind !== 'inbound' && kind !== 'output') || !id || !UUID.test(id)) return null
    return { kind, id }
}
export function batchHref(kind: string, id: string): string {
    return kind === 'inbound' ? `/inbound/${id}/edit` : `/output/${id}/edit`
}
export function assayHref(kind: string, batchId: string, assayId: string): string {
    return kind === 'inbound' ? `/inbound/${batchId}/assays/${assayId}` : `/output/${batchId}/assays/${assayId}`
}
