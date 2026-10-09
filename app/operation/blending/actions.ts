'use server'

// MES-5b-3:配料计划的五个动作 —— 全部转达给数据库,页面不自己判断(Q17–Q20)。拒绝按名翻译(localizeBlendingError)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeBlendingError } from './blendingErrorCodes'

export type BlendState = { error?: string }

export type PlanLine = { inbound_batch_id?: string; output_batch_id?: string; planned_kg: number }
/** 一条目标:从合同的一条品位规格抄(grade_spec_id),或人敲的(metal + 界)。 */
export type PlanTarget = { grade_spec_id: string } | { metal: string; min_pct: number | null; max_pct: number | null }

export type PlanPayload = {
    output_material_id: string
    source_contract_id: string | null
    notes: string | null
    targets: PlanTarget[]
    lines: PlanLine[]
}

export async function createBlendingPlan(payload: PlanPayload): Promise<BlendState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_blending_plan', {
        p_output_material_id: payload.output_material_id,
        p_lines: payload.lines,
        p_targets: payload.targets,
        p_source_contract_id: payload.source_contract_id ?? undefined,
        p_notes: payload.notes ?? undefined,
    })
    if (error) return { error: await localizeBlendingError(error.message) }
    revalidatePath('/operation/blending')
    redirect(`/operation/blending/${(data as { plan_id: string }).plan_id}`)
}

export async function amendBlendingPlan(id: string, payload: PlanPayload): Promise<BlendState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_blending_plan', {
        p_plan_id: id,
        p_output_material_id: payload.output_material_id,
        p_lines: payload.lines,
        p_targets: payload.targets,
        p_source_contract_id: payload.source_contract_id ?? undefined,
        p_notes: payload.notes ?? undefined,
    })
    if (error) return { error: await localizeBlendingError(error.message) }
    revalidatePath(`/operation/blending/${id}`)
    revalidatePath('/operation/blending')
    return {}
}

export async function releaseBlendingPlan(id: string): Promise<BlendState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('release_blending_plan', { p_plan_id: id })
    if (error) return { error: await localizeBlendingError(error.message) }
    revalidatePath(`/operation/blending/${id}`)
    revalidatePath('/operation/blending')
    return {}
}

export async function cancelBlendingPlan(id: string, reason: string): Promise<BlendState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_blending_plan', { p_plan_id: id, p_reason: reason })
    if (error) return { error: await localizeBlendingError(error.message) }
    revalidatePath(`/operation/blending/${id}`)
    revalidatePath('/operation/blending')
    return {}
}

export async function executeBlendingPlan(id: string, payload: {
    process_date: string
    started_at: string
    ended_at: string
    shift_code: string
    actual: { line_id: string; actual_kg: number }[]
    weight_kg: number
}): Promise<BlendState> {
    // 【加工日不给默认值】它决定这一炉落在哪个月(FIN-10 的规矩)—— 空就由服务端按名拒,不在这里补今天。
    const supabase = await createClient()
    const { error } = await supabase.rpc('execute_blending_plan', {
        p_plan_id: id,
        p_process_date: payload.process_date,
        p_started_at: payload.started_at,
        p_ended_at: payload.ended_at,
        p_shift_code: payload.shift_code,
        p_actual: payload.actual,
        p_weight_kg: payload.weight_kg,
    })
    if (error) return { error: await localizeBlendingError(error.message) }
    revalidatePath(`/operation/blending/${id}`)
    revalidatePath('/operation/blending')
    revalidatePath('/operation/processing')
    return {}
}
