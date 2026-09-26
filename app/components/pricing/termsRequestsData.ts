// app/components/pricing/termsRequestsData.ts
// ★ APR-8(Tim 2026-09-26,grilling Q8):公式页与合同页上"条款申请"那一块读的数据 —— 服务端取、服务端摊平。
//   读 terms_requests_visible():在等的全部 + 最近了结的几张;snapshot 由库按价格码与合同那一侧遮蔽,
//   读不到时是 null —— 屏幕画「受限」,不画一张空的差别表(一张空表读起来像"什么都没改")。
//   ☞ 差别是【这里】算的,不是库算的:库冻结了两份完整的条款(公式:current / proposed;合同:
//     last_approved / current),这里逐项比出哪几行变了。两份都在 snapshot 里,CFO 批的就是它们。
import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { formatAuditStamp } from '@/lib/dates'

type Translate = (key: string, params?: Record<string, string>) => string

export type TermsRequestKind = 'formula_create' | 'formula_change' | 'formula_reactivate' | 'contract_activate'
export type TermsRequestStatus = 'submitted' | 'approved' | 'rejected' | 'withdrawn'

export type TermsDiffRow = { key: string; label: string; before: string; after: string; changed: boolean }

export type TermsRequestView = {
    id: string
    kind: TermsRequestKind
    status: TermsRequestStatus
    label: string
    subjectCode: string
    subjectName: string | null
    reason: string
    createdText: string
    raisedBy: string | null
    raisedByMe: boolean
    decidedBy: string | null
    decisionNotes: string | null
    withdrawReason: string | null
    /** null = 这位读者看不见这组条款(价格码 / 合同那一侧)—— 画「受限」 */
    diff: TermsDiffRow[] | null
    /** 左列说的是哪一份:提交时的条款,还是上一次批准时的那一份;none = 新公式,左列是空的 */
    beforeIs: 'current' | 'last_approved' | 'none'
    /** 已经摊平成句子的"哪些单据会用它" */
    usage: string[]
}

type Row = {
    id: string; kind: TermsRequestKind; status: TermsRequestStatus; label: string
    formula_id: string | null; contract_id: string | null; subject_code: string | null
    reason: string; proposed: Record<string, unknown> | null; snapshot: Record<string, unknown> | null
    created_at: string; created_by_email: string | null; raised_by_me: boolean
    decided_at: string | null; decided_by_email: string | null; decision_notes: string | null
    withdrawn_at: string | null; withdraw_reason: string | null
}

type Terms = Record<string, unknown>

const FORMULA_FIELDS = ['name', 'direction', 'price_basis', 'average_days', 'price_index',
    'treatment_charge_usd_per_tonne', 'flat_discount_pct', 'supplier_id', 'customer_id', 'notes'] as const
const CONTRACT_SECTIONS = ['grade_specs', 'insurance_obligations', 'volume_commitments', 'pricing_terms',
    'settlement_terms', 'refining_charges', 'penalty_elements'] as const

const text = (v: unknown): string => (v === null || v === undefined || v === '' ? '—' : String(v))

/** 一行条款(去掉了 id 的 jsonb)读成一句 "键 值 · 键 值" —— 顺序按键名,于是同一行读出同一串 */
function rowText(r: unknown): string {
    if (r === null || typeof r !== 'object') return text(r)
    return Object.keys(r as Terms).sort()
        .filter((k) => (r as Terms)[k] !== null && (r as Terms)[k] !== undefined)
        .map((k) => `${k} ${String((r as Terms)[k])}`)
        .join(' · ')
}

function formulaDiff(before: Terms | null, after: Terms | null, t: Translate, names: Map<string, string>): TermsDiffRow[] {
    const shown = (k: string, v: unknown) =>
        (k === 'supplier_id' || k === 'customer_id') && typeof v === 'string' ? (names.get(v) ?? v) : text(v)
    const rows: TermsDiffRow[] = FORMULA_FIELDS.map((k) => {
        const b = before ? shown(k, before[k]) : '—'
        const a = after ? shown(k, after[k]) : '—'
        return { key: k, label: t('termsRequest.field.' + k), before: b, after: a, changed: before !== null && b !== a }
    })
    const metalsOf = (x: Terms | null) => new Map(
        ((x?.metals as { metal: string; payable_pct: number }[] | undefined) ?? []).map((m) => [m.metal, String(m.payable_pct)]))
    const bm = metalsOf(before)
    const am = metalsOf(after)
    for (const metal of [...new Set([...bm.keys(), ...am.keys()])].sort()) {
        const b = before ? (bm.get(metal) ?? t('termsRequest.notPaid')) : '—'
        const a = am.get(metal) ?? t('termsRequest.notPaid')
        rows.push({ key: 'metal:' + metal, label: t('termsRequest.field.payable', { metal }), before: b, after: a,
                    changed: before !== null && b !== a })
    }
    return rows
}

function contractDiff(before: Terms | null, after: Terms | null, t: Translate): TermsDiffRow[] {
    const header = (x: Terms | null) => (x?.header as Terms | undefined) ?? null
    const hb = header(before)
    const ha = header(after)
    const keys = [...new Set([...Object.keys(hb ?? {}), ...Object.keys(ha ?? {})])]
        .filter((k) => !['side', 'deleted_at'].includes(k)).sort()
    const rows: TermsDiffRow[] = keys.map((k) => {
        const b = before ? text(hb?.[k]) : '—'
        const a = text(ha?.[k])
        return { key: 'header:' + k, label: k, before: b, after: a, changed: before !== null && b !== a }
    })
    for (const s of CONTRACT_SECTIONS) {
        const list = (x: Terms | null) => ((x?.[s] as unknown[] | undefined) ?? []).map(rowText)
        const b = before ? (list(before).join('\n') || t('termsRequest.noneFiled')) : '—'
        const a = list(after).join('\n') || t('termsRequest.noneFiled')
        rows.push({ key: 'section:' + s, label: t('termsRequest.section.' + s), before: b, after: a,
                    changed: before !== null && b !== a })
    }
    return rows
}

export async function loadTermsRequests(
    supabase: SupabaseClient<Database>,
    t: Translate,
    opts: { which: 'formula' | 'contract'; formulaId?: string; recent?: number },
): Promise<{ open: TermsRequestView[]; history: TermsRequestView[] }> {
    const rows = (mustRows(await supabase.rpc('terms_requests_visible', {
        p_recent: opts.recent ?? 10,
        p_formula_id: opts.formulaId,
    }), 'terms_requests_visible') as unknown as Row[])
        .filter((r) => (opts.which === 'contract') === (r.contract_id !== null))

    // 公式条款里的对手方是 id —— 摊平成名字(读不到的留 id,不编一个)
    const ids = new Set<string>()
    for (const r of rows) {
        const s = r.snapshot ?? {}
        for (const x of [s.current, s.proposed, s.last_approved] as (Terms | null | undefined)[]) {
            for (const k of ['supplier_id', 'customer_id']) if (x && typeof x[k] === 'string') ids.add(x[k] as string)
        }
    }
    const names = new Map<string, string>()
    if (ids.size > 0) {
        const [sup, cus] = await Promise.all([
            supabase.from('supplier_lookup').select('id, legal_name').in('id', [...ids]),
            supabase.from('customer_lookup').select('id, legal_name').in('id', [...ids]),
        ])
        for (const x of [...mustRows(sup, 'supplier_lookup'), ...mustRows(cus, 'customer_lookup')] as
                 { id: string | null; legal_name: string | null }[]) {
            if (x.id && x.legal_name) names.set(x.id, x.legal_name)
        }
    }

    const view = (r: Row): TermsRequestView => {
        const s = r.snapshot
        const isContract = r.kind === 'contract_activate'
        let diff: TermsDiffRow[] | null = null
        let beforeIs: TermsRequestView['beforeIs'] = 'none'
        const usage: string[] = []
        if (s) {
            if (isContract) {
                const last = (s.last_approved as Terms | null) ?? null
                beforeIs = last ? 'last_approved' : 'none'
                diff = contractDiff(last, (s.current as Terms | null) ?? null, t)
                usage.push(t('termsRequest.usage.linked', { n: String(s.linked_documents ?? 0) }))
            } else {
                const cur = r.kind === 'formula_create' ? null : ((s.current as Terms | null) ?? null)
                beforeIs = cur ? 'current' : 'none'
                diff = formulaDiff(cur, (s.proposed as Terms | null) ?? null, t, names)
                const u = (s.usage as Record<string, number> | undefined) ?? {}
                usage.push(t('termsRequest.usage.committed', {
                    lines: String(u.po_lines_committed ?? 0), batches: String(u.batches_committed ?? 0) }))
                usage.push(t('termsRequest.usage.uncommitted', { n: String(u.batches_uncommitted ?? 0) }))
                usage.push(t('termsRequest.usage.future'))
            }
        }
        return {
            id: r.id, kind: r.kind, status: r.status, label: r.label,
            subjectCode: r.subject_code ?? '—',
            subjectName: s ? String((isContract ? s.title : s.formula_name) ?? '') || null : null,
            reason: r.reason,
            createdText: formatAuditStamp(r.created_at),
            raisedBy: r.created_by_email, raisedByMe: r.raised_by_me,
            decidedBy: r.decided_by_email, decisionNotes: r.decision_notes, withdrawReason: r.withdraw_reason,
            diff, beforeIs, usage,
        }
    }
    const all = rows.map(view)
    return { open: all.filter((v) => v.status === 'submitted'), history: all.filter((v) => v.status !== 'submitted') }
}

/** decide_terms_request 的五个门码(与 approval_chain_gates 那一行逐字同源) */
export const TERMS_DECIDE_CODES = ['module.pricing.view', 'data.view_prices', 'data.view_purchase_prices',
    'module.suppliers.view', 'module.customers.view'] as const

/** 读者缺的第一个门码;null = 五个都持(谁能批仍由库裁:二级、不是提单人) */
export async function firstMissingDecideCode(can: (code: string) => Promise<boolean>): Promise<string | null> {
    const held = await Promise.all(TERMS_DECIDE_CODES.map((c) => can(c)))
    const i = held.findIndex((h) => !h)
    return i === -1 ? null : TERMS_DECIDE_CODES[i]
}
