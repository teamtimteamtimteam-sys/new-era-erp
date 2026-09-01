'use server'

// WO-1c:工单的五个动作 —— 全部转达给数据库,页面不自己判断。
// 拒绝按名翻译(localizeProcessingError),屏幕上不出现机器串。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { redirect } from 'next/navigation'
import { localizeProcessingError } from '../errorCodes'

export type WoState = { error?: string }

export type PlannedLine = { material_id: string; planned_qty: number }
// PROC-SUPPORT-1(R3):出处随每一行走。**basis 允许是空串** —— 客户端不拦,
// 服务端按名拒(WO_EXPECTED_BASIS_REQUIRED)。在这里拦会让"没人说过"变成一次
// 静默的客户端失败,而屏幕上唯一说得清这件事的地方是那条具名拒绝。
export type ExpectedLine = {
    material_id: string
    expected_qty: number
    basis: string
    basis_reference?: string
}

export async function createWorkOrder(payload: {
    lines: PlannedLine[]
    expected: ExpectedLine[]
    scheduled_date: string | null
    notes: string | null
}): Promise<WoState> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('create_work_order', {
        p_lines: payload.lines,
        p_expected: payload.expected.length > 0 ? payload.expected : null,
        // 【排产日不给默认值】空就是空 —— 一个补出来的今天会把"没排期"伪装成
        // "排在今天"(见 db/tables/work_orders.sql 的列注释)。
        p_scheduled_date: payload.scheduled_date,
        p_notes: payload.notes,
    } as never)
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath('/processing/orders')
    redirect(`/processing/orders/${(data as { work_order_id: string }).work_order_id}`)
}

export async function releaseWorkOrder(id: string): Promise<WoState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('release_work_order', { p_work_order_id: id } as never)
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/processing/orders/${id}`)
    revalidatePath('/processing/orders')
    return {}
}

export async function closeWorkOrder(id: string, reason: string): Promise<WoState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_work_order',
        { p_work_order_id: id, p_reason: reason } as never)
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/processing/orders/${id}`)
    revalidatePath('/processing/orders')
    return {}
}

export async function cancelWorkOrder(id: string, reason: string): Promise<WoState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('cancel_work_order',
        { p_work_order_id: id, p_reason: reason } as never)
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/processing/orders/${id}`)
    revalidatePath('/processing/orders')
    return {}
}

export async function amendWorkOrder(payload: {
    id: string
    reason: string
    lines?: { material_id: string; planned_qty: number | null }[]
    // 改单这一侧:basis 是【可选】的 —— 不给就是"这一次不改出处"。
    // 新增一行时服务端仍然必填(amend_work_order 的 add 分支)。
    expected?: {
        material_id: string
        expected_qty: number | null
        basis?: string
        basis_reference?: string
    }[]
    scheduled_date?: string | null
    set_scheduled?: boolean
}): Promise<WoState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('amend_work_order', {
        p_work_order_id: payload.id,
        p_reason: payload.reason,
        // 【p_set_scheduled 这个布尔不是多余的】NULL 有两个意思:"不改这一项"
        // 与"把排期清掉"。少了它,"取消排期"就表达不出来。
        p_scheduled_date: payload.scheduled_date ?? null,
        p_set_scheduled: payload.set_scheduled ?? false,
        p_notes: null,
        p_set_notes: false,
        p_lines: payload.lines ?? null,
        p_expected: payload.expected ?? null,
    } as never)
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/processing/orders/${payload.id}`)
    revalidatePath('/processing/orders')
    return {}
}
