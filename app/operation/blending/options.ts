// app/operation/blending/options.ts
// MES-5b-3:新建 / 改一份配料计划要的四份清单 —— 产出物料、候选批次、合同与它们的品位规格、金属。
//   ★ 形态从【配料这道工序自己的声明】读(operation_type_input_forms / _output_forms),不在这里写一张码表:
//     收哪些、出哪些由数据回答,库里的判据(BLEND_LINE_FORM_NOT_BLENDABLE / BLEND_OUTPUT_FORM_NOT_BLENDABLE)读的是同两张表。
//   ★ 读不到的就是读不到:没有进料查看码的人,进料批这一组是空的(RLS),页面照直说"受限",不说"没有"。
import type { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'

type Supa = Awaited<ReturnType<typeof createClient>>

export type MaterialOption = { id: string; code: string; name: string; form_code: string | null }
export type BatchOption = { key: string; kind: 'inbound' | 'output'; id: string; code: string; materialCode: string; remaining: number }
export type SpecOption = { id: string; metal: string; min_pct: number | null; max_pct: number | null; material_id: string | null; materialCode: string | null }
export type ContractOption = { id: string; code: string; title: string; specs: SpecOption[] }
export type MetalOption = { code: string; name: string }

export async function loadBlendingOptions(supabase: Supa, locale: string) {
    const [inForms, outForms] = await Promise.all([
        supabase.from('operation_type_input_forms').select('form_code').eq('operation_type_code', 'blending'),
        supabase.from('operation_type_output_forms').select('form_code').eq('operation_type_code', 'blending'),
    ])
    const inputForms = (mustRows(inForms, 'operation_type_input_forms') as { form_code: string }[]).map((r) => r.form_code)
    const outputForms = (mustRows(outForms, 'operation_type_output_forms') as { form_code: string }[]).map((r) => r.form_code)
    const allForms = [...new Set([...inputForms, ...outputForms])]

    const mats = allForms.length === 0 ? [] : mustRows(
        await supabase.from('material_lookup').select('id, code, name, form_code').is('deleted_at', null).in('form_code', allForms).order('code'),
        'material_lookup') as MaterialOption[]
    const outputMaterials = mats.filter((m) => m.form_code && outputForms.includes(m.form_code))
    const inputMatIds = mats.filter((m) => m.form_code && inputForms.includes(m.form_code)).map((m) => m.id)
    const matCode = new Map(mats.map((m) => [m.id, m.code]))

    const [canIn, canOut] = await Promise.all([can('module.inbound.view'), can('module.output.view')])
    const ib = !canIn || inputMatIds.length === 0 ? [] : mustRows(
        await supabase.from('inbound_batches_masked').select('id, code, material_id, remaining_qty, unit')
            .is('deleted_at', null).in('material_id', inputMatIds).gt('remaining_qty', 0).eq('unit', 'kg').order('code'),
        'inbound_batches_masked') as { id: string; code: string; material_id: string; remaining_qty: number }[]
    const ob = !canOut || inputMatIds.length === 0 ? [] : mustRows(
        await supabase.from('output_batches').select('id, code, material_id, remaining_qty, unit')
            .is('deleted_at', null).in('material_id', inputMatIds).gt('remaining_qty', 0).eq('unit', 'kg').order('code'),
        'output_batches') as { id: string; code: string; material_id: string; remaining_qty: number }[]
    const batches: BatchOption[] = [
        ...ib.map((b) => ({ key: 'inbound:' + b.id, kind: 'inbound' as const, id: b.id, code: b.code, materialCode: matCode.get(b.material_id) ?? '—', remaining: Number(b.remaining_qty) })),
        ...ob.map((b) => ({ key: 'output:' + b.id, kind: 'output' as const, id: b.id, code: b.code, materialCode: matCode.get(b.material_id) ?? '—', remaining: Number(b.remaining_qty) })),
    ]

    // 合同:读得到的那几份(合同的读规则按客户 / 供应商查看码)与它们的品位规格
    const contracts = mustRows(
        await supabase.from('contracts').select('id, code, title').order('code', { ascending: false }), 'contracts') as
        { id: string; code: string; title: string }[]
    const specs = contracts.length === 0 ? [] : mustRows(
        await supabase.from('contract_grade_specs').select('id, contract_id, metal, min_pct, max_pct, material_id')
            .in('contract_id', contracts.map((c) => c.id)),
        'contract_grade_specs') as { id: string; contract_id: string; metal: string; min_pct: number | null; max_pct: number | null; material_id: string | null }[]
    const contractOptions: ContractOption[] = contracts.map((c) => ({
        id: c.id, code: c.code, title: c.title,
        specs: specs.filter((s) => s.contract_id === c.id).map((s) => ({
            id: s.id, metal: s.metal, min_pct: s.min_pct == null ? null : Number(s.min_pct), max_pct: s.max_pct == null ? null : Number(s.max_pct),
            material_id: s.material_id, materialCode: s.material_id ? matCode.get(s.material_id) ?? null : null,
        })),
    }))

    const metals = mustRows(
        await supabase.from('substances').select('code, name_en, name_zh').order('code'), 'substances') as
        { code: string; name_en: string; name_zh: string }[]
    const metalOptions: MetalOption[] = metals.map((m) => ({ code: m.code, name: locale === 'zh' ? m.name_zh : m.name_en }))

    return { outputMaterials, batches, contracts: contractOptions, metals: metalOptions, canIn, canOut }
}
