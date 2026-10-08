// app/operation/balance/labels.ts
// MES-5b-1(2026-10-08):物料平衡、得率与批次去向三处共用的名字 —— 工序、产出形态、损耗类别取自各自的字典(按界面语言选一个,
//   不拼两种);余数的状态与损耗的来由是本刀的几个固定词。字典里查不到的代码原样印出来(不印成空 —— 一个空格读起来像"没有")。
import type { createClient } from '@/lib/supabase/server'
import type { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'

type Supa = Awaited<ReturnType<typeof createClient>>
type T = Awaited<ReturnType<typeof getTranslations>>

export type MonthlyLine = {
    scope: 'plant' | 'operation'
    operation_type_code: string | null
    line: 'input' | 'output' | 'loss' | 'remainder' | 'pass_through' | 'reversed' | 'not_kg'
    line_key: string | null
    basis: string | null
    qty: number | string | null
    runs: number | string
}

const REMAINDER_ORDER = ['closed_within', 'closed_explained', 'open', 'before_closure']
export const remainderOrder = (k: string | null) => { const i = REMAINDER_ORDER.indexOf(k ?? ''); return i < 0 ? 99 : i }

export async function labelMaps(supabase: Supa, locale: string, t: T) {
    const [formRes, lossRes, opRes] = await Promise.all([
        supabase.from('material_forms').select('code, name_en, name_zh, sort_order'),
        supabase.from('loss_categories').select('code, name_en, name_zh, sort_order'),
        supabase.from('operation_types').select('code, name_en, name_zh, sort_order'),
    ])
    const pick = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)
    const forms = new Map(mustRows(formRes, 'material_forms').map((r) => [r.code, r]))
    const losses = new Map(mustRows(lossRes, 'loss_categories').map((r) => [r.code, r]))
    const ops = new Map(mustRows(opRes, 'operation_types').map((r) => [r.code, r]))
    const remainderText: Record<string, string> = {
        closed_within: t('massBalance.remClosedWithin'),
        closed_explained: t('massBalance.remClosedExplained'),
        open: t('massBalance.remOpen'),
        before_closure: t('massBalance.remBeforeClosure'),
    }
    return {
        form: (code: string | null) => {
            if (!code || code === '(none)') return t('massBalance.noForm')
            const f = forms.get(code)
            return f ? pick(f) : code
        },
        formSort: (code: string | null) => forms.get(code ?? '')?.sort_order ?? 9999,
        loss: (code: string | null) => { const l = losses.get(code ?? ''); return l ? pick(l) : (code ?? '') },
        lossSort: (code: string | null) => losses.get(code ?? '')?.sort_order ?? 9999,
        basis: (b: string | null) => (b === 'derived' ? t('massBalance.basisDerived') : t('massBalance.basisMeasured')),
        remainder: (state: string | null) => remainderText[state ?? ''] ?? (state ?? ''),
        op: (code: string | null) => {
            if (!code) return t('massBalance.noOperation')
            const o = ops.get(code)
            return o ? pick(o) : code
        },
        opSort: (code: string | null) => (code ? (ops.get(code)?.sort_order ?? 9998) : 9999),
    }
}
