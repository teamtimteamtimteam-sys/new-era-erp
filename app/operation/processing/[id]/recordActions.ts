'use server'

// MES-4a(2026-10-07,Step 0 Q10–Q30,Tim):一张加工单提交之后还能往上记的那几样 —— 参数与指标、异常事件、物料平衡的结算、
// 抬头的更正。每一样都只经它自己的函数写(表上没有给 authenticated 的写策略;直写一律 PROCESSING_THROUGH_FUNCTION_ONLY),
// 每一样都【只追加】:改一个值 = 记一条更正它的新行,连同理由;旧的那一行留着。
//
// 【这里不校验规则】值合不合类型、事件缺不缺处理措施、平衡要不要解释 —— 全由函数判,这里只把它的拒绝翻成人话。
// 屏幕上再判一遍就是同一条规则的第二份实现(AGENTS.md「一个预览的屏幕问数据库」)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import type { Json } from '@/lib/database.types'
import { localizeProcessingError } from '../../errorCodes'

export type RecordState = { error?: string }

async function done(runId: string, error: { message: string } | null): Promise<RecordState> {
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    revalidatePath('/operation/processing')
    return {}
}

/** 记一个还没记过的值(Q11)。 */
export async function recordRunValue(runId: string, fieldCode: string, value: Json): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_run_value', { p_run_id: runId, p_field_code: fieldCode, p_value: value })
    return done(runId, error)
}

/** 更正一个已经记过的值 —— 带理由;value 为 null = 撤回(更正成"没有值",看得见)。 */
export async function correctRunValue(runId: string, valueId: number, value: Json, reason: string): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_run_value', { p_value_id: valueId, p_value: value, p_reason: reason })
    return done(runId, error)
}

export type EventInput = {
    event_type: string
    /** 带时区的 ISO(浏览器那一侧换好的) */
    occurred_at: string | null
    duration_min: number | null
    action_taken: string
    responsible_person: string
    notes: string
}

/** 记一件异常事件(Q15):种类、时刻、时长、处理措施、责任人。 */
export async function recordRunEvent(runId: string, e: EventInput): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('record_run_event', {
        p_run_id: runId, p_event_type: e.event_type, p_occurred_at: e.occurred_at as string,
        p_duration_min: e.duration_min as number, p_action_taken: e.action_taken,
        p_responsible_person: e.responsible_person, p_notes: e.notes || undefined,
    })
    return done(runId, error)
}

/** 更正一件事件(整条换成新的内容)或撤回它(withdraw = true)—— 都带理由。 */
export async function correctRunEvent(runId: string, eventId: number, e: EventInput, withdraw: boolean, reason: string): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_run_event', {
        p_event_id: eventId, p_event_type: e.event_type, p_occurred_at: e.occurred_at as string,
        p_duration_min: e.duration_min as number, p_action_taken: e.action_taken,
        p_responsible_person: e.responsible_person, p_notes: e.notes, p_withdraw: withdraw, p_reason: reason,
    })
    return done(runId, error)
}

/** 结算这一炉的物料平衡(Q19–Q20)。差额不在容差内(或容差没给)时必须写解释 —— 函数按名拒。 */
export async function closeRunBalance(runId: string, explanation: string): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('close_run_balance', {
        p_run_id: runId, p_explanation: explanation.trim() || undefined,
    })
    return done(runId, error)
}

/** 更正抬头的一个字段(Q30):开始 / 结束 / 班次 / 机器 / 配方版本 / 备注。旧值、新值、理由记成一行。 */
export async function correctRunHeader(runId: string, field: string, value: string, reason: string): Promise<RecordState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_run_header', {
        p_run_id: runId, p_field: field, p_value: value, p_reason: reason,
    })
    return done(runId, error)
}
