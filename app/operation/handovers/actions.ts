'use server'

// app/operation/handovers/actions.ts
// PROC-SUPPORT-1(R4):提交与签收一次交接班。
//
// 【两个动作,两个 server action,而不是一个带 mode 参数的】提交与签收的
// 【权威不同】:提交是交班的人说的话,签收是接班的人说的话,而数据库那一侧
// 只允许被点名的接班人签收(HANDOVER_ACK_NOT_INCOMING)。合成一个入口,
// 那条区别在代码里就先被抹平一次。

import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeProcessingError } from '@/app/operation/errorCodes'
import type { Database } from '@/lib/database.types'

export type HandoverItemInput = { item_type_code: string; body: string }

export type SubmitHandoverPayload = {
    shift_code: string
    handover_date: string
    outgoing_employee_id: string
    incoming_employee_id: string
    notes: string
    items: HandoverItemInput[]
    downtime_ids: string[]
}

export type HandoverState = { error?: string; id?: string }

export async function submitShiftHandover(payload: SubmitHandoverPayload): Promise<HandoverState> {
    const supabase = await createClient()
    // 【客户端一律不拦,原样送上去】与 commit_processing_run 那一侧同一条:
    // 界面是第一道,函数是权威的那一道。空班次/空日期/同一个人,都由那边
    // 按名拒,于是屏幕上出现的是一句说得清下一步的话,而不是一次静默的失败。
    const { data, error } = await supabase.rpc('submit_shift_handover', {
        p_shift_code: payload.shift_code,
        p_handover_date: payload.handover_date || null,
        p_outgoing_employee_id: payload.outgoing_employee_id || null,
        p_incoming_employee_id: payload.incoming_employee_id || null,
        p_notes: payload.notes,
        // 【空条目在这里就滤掉】—— 一个只有空白的条目不是内容,而服务端
        // 也会拒它(HANDOVER_ITEM_BODY_REQUIRED)。这里滤掉的是"三个空槽位",
        // 不是"一条被写坏的内容":后者仍然要撞到那条具名拒绝上。
        p_items: payload.items.filter((i) => i.item_type_code && i.body.trim() !== ''),
        p_downtime_ids: payload.downtime_ids.length > 0 ? payload.downtime_ids : null,
    } as unknown as Database['public']['Functions']['submit_shift_handover']['Args'])

    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath('/operation/handovers')
    return { id: data as unknown as string }
}

export async function acknowledgeShiftHandover(handoverId: string): Promise<HandoverState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('acknowledge_shift_handover', {
        p_handover_id: handoverId,
    } as unknown as Database['public']['Functions']['acknowledge_shift_handover']['Args'])

    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath('/operation/handovers')
    return {}
}
