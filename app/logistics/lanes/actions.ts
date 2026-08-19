'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeLogisticsError } from '../logisticsErrorCodes'

export type Result = { error: string } | { success: true }
const P = '/logistics/lanes'
async function fail(m: string): Promise<Result> { return { error: await localizeLogisticsError(m) } }

export async function addPort(code: string, name: string, country: string | null): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('ports').insert({ code: code.trim(), name: name.trim(), country })
    if (error) return fail(error.message)
    revalidatePath(P); return { success: true }
}

export async function addLane(origin: string, destination: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('lanes').insert({ origin_port_id: origin, destination_port_id: destination })
    if (error) return fail(error.message)
    revalidatePath(P); return { success: true }
}

export async function addRequirement(laneId: string, documentType: string, regime: string | null): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('lane_document_requirements')
        .insert({ lane_id: laneId, document_type: documentType.trim(), regime })
    if (error) return fail(error.message)
    revalidatePath(P); return { success: true }
}

export async function removeRequirement(id: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('lane_document_requirements')
        .update({ deleted_at: new Date().toISOString() }).eq('id', id)
    if (error) return fail(error.message)
    revalidatePath(P); return { success: true }
}

// 【把一条航段标成"看过了"】—— 这一步是 not_defined 与 defined_empty 的唯一区别,
// 所以它必须是一个【人的动作】,系统永不代劳(lanes.checklist_reviewed_at 的列注释)。
export async function markLaneReviewed(laneId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('lanes')
        .update({ checklist_reviewed_at: new Date().toISOString() }).eq('id', laneId)
    if (error) return fail(error.message)
    revalidatePath(P); return { success: true }
}
