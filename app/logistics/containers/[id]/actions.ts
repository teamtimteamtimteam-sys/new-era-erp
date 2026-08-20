'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeLogisticsError } from '../../logisticsErrorCodes'

export type Result = { error: string } | { success: true }
async function fail(m: string): Promise<Result> { return { error: await localizeLogisticsError(m) } }
function touch(id: string) { revalidatePath(`/logistics/containers/${id}`) }

export async function saveContainerHead(id: string, input: {
    container_number: string | null; vessel: string | null; voyage: string | null
    bl_number: string | null; notes: string | null
    // LOG-5b:预计到达。【空字符串要落成 NULL,不是落成空串】——
    // 一个被撤回的估计的正确写法是"没有 ETA",而 date 列收到 '' 会直接报类型错。
    // 清空是一个【正当动作】,不是一次失败(container_eta_overdue 对 NULL 沉默)。
    expected_arrival_date: string | null
    // CTN-FWD:承运方。【既有的这扇门装得下它 —— 查证过,不是假设】:
    // forwarder_id 对 authenticated 有列级 UPDATE 授权,containers 的写策略是
    // ALL(module.purchasing.edit),而唯一挂在它上面的守卫
    // guard_container_forwarder 【允许 NULL、允许货代】,只按名拒非货代
    // (CONTAINER_FORWARDER_NOT_A_FORWARDER)。所以不需要新的写入路径。
    // 【空字符串 → NULL】清回"不指定"是一个正当动作,不是一次失败。
    forwarder_id: string | null
}): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('containers').update(input as never).eq('id', id)
    if (error) return fail(error.message)
    touch(id); return { success: true }
}

// 装箱 / 拆箱都走 RPC —— shipments 上没有 UPDATE 策略,
// 而 container_id 是它唯一可改的列(guard_shipment_append_only 按列放行)。
export async function attachShipment(containerId: string, shipmentId: string): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('attach_shipment_to_container', {
        p_shipment_id: shipmentId, p_container_id: containerId,
    } as never)
    if (error) return fail(error.message)
    touch(containerId); revalidatePath('/logistics/containers'); return { success: true }
}

export async function detachShipment(containerId: string, shipmentId: string, reason: string): Promise<Result> {
    const supabase = await createClient()
    // 【空白交给服务端判,而且判法要与库一致】—— 库里是 btrim 之后判空,
    // 所以这里不做客户端的 required 就算数:传什么就让库怎么答。
    const { error } = await supabase.rpc('detach_shipment_from_container', {
        p_shipment_id: shipmentId, p_reason: reason,
    } as never)
    if (error) return fail(error.message)
    touch(containerId); revalidatePath('/logistics/containers'); return { success: true }
}

export async function addMilestone(containerId: string, input: {
    milestone: string; event_date: string; note: string | null
}): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('container_milestones').insert({
        container_id: containerId, milestone: input.milestone,
        event_date: input.event_date, note: input.note,
    } as never)
    if (error) return fail(error.message)
    touch(containerId); return { success: true }
}

export async function instantiateDocuments(containerId: string): Promise<Result | { lane_state: string; created: number }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('instantiate_container_documents', {
        p_container_id: containerId,
    } as never)
    if (error) return fail(error.message)
    touch(containerId)
    return data as unknown as { lane_state: string; created: number }
}

export async function setDocumentStatus(
    containerId: string, docId: string, status: string, naReason: string | null
): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('container_documents')
        .update({ status, na_reason: status === 'not_applicable' ? naReason : null } as never)
        .eq('id', docId)
    if (error) return fail(error.message)
    touch(containerId); return { success: true }
}

export async function addDocument(containerId: string, documentType: string, regime: string | null): Promise<Result> {
    const supabase = await createClient()
    const { error } = await supabase.from('container_documents').insert({
        container_id: containerId, document_type: documentType, regime, from_lane: false,
    } as never)
    if (error) return fail(error.message)
    touch(containerId); return { success: true }
}
