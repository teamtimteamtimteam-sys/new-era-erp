'use server'

// app/customers/chaseActions.ts
// CHASE-1:客户档案页上催收那一段的服务端动作。
//
// 【两个动作都只是转发,一行算术都没有】AGENTS.md 那条规矩(这个仓库为它付过
// 四次账):要预览一次写入的屏幕【要问数据库它会是什么】,不许在 TypeScript 里
// 把规则重写一遍。欠款那个数尤其如此 —— 它必须与对账单印的那个数是同一个,
// 而做到这一点的唯一办法是【调同一支函数】,不是"用同样的方法算"。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeChaseError } from '@/app/finance/collections/chaseErrorCodes'

export type ChaseState = { error?: string; success?: boolean; chaseId?: string }

export type ChaseDocument = { subject_type: string; subject_id: string }
export type ChasePromise = { amount: string; currency: string; promised_date: string }

export async function collectionContext(
    customerId: string, asOf: string,
): Promise<ChaseState & { data?: unknown }> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('customer_collection_context', {
        p_customer_id: customerId, p_as_of: asOf,
    })
    if (error) return { error: await localizeChaseError(error.message) }
    return { success: true, data }
}

export async function recordChase(input: {
    customerId: string
    chasedOn: string
    channel: string
    reached: boolean
    summary: string
    contactedPerson?: string | null
    documents?: ChaseDocument[]
    promise?: ChasePromise | null
    supersedes?: string | null
    supersedeReason?: string | null
}): Promise<ChaseState> {
    const supabase = await createClient()
    const person = (input.contactedPerson ?? '').trim()
    const reason = (input.supersedeReason ?? '').trim()
    // 【空串不传成参数】生成的类型把带默认值的参数标成可选;而语义上
    // "不传" = 用函数自己的默认值,与传 null 一致。
    const { data, error } = await supabase.rpc('record_collection_chase', {
        p_customer_id: input.customerId,
        p_chased_on: input.chasedOn,
        p_channel: input.channel,
        p_reached: input.reached,
        p_summary: input.summary,
        ...(person !== '' ? { p_contacted_person: person } : {}),
        ...(input.documents && input.documents.length > 0 ? { p_documents: input.documents } : {}),
        ...(input.promise ? { p_promise: input.promise } : {}),
        ...(input.supersedes ? { p_supersedes: input.supersedes } : {}),
        ...(reason !== '' ? { p_supersede_reason: reason } : {}),
    })
    if (error) return { error: await localizeChaseError(error.message) }
    revalidatePath(`/customers/${input.customerId}`)
    return { success: true, chaseId: (data as { chase_id?: string } | null)?.chase_id }
}

export async function recordPromiseOutcome(
    customerId: string, promiseId: string, outcome: string, note: string | null,
): Promise<ChaseState> {
    const supabase = await createClient()
    const trimmed = (note ?? '').trim()
    const { error } = await supabase.rpc('record_promise_outcome', {
        p_promise_id: promiseId,
        p_outcome: outcome,
        ...(trimmed !== '' ? { p_note: trimmed } : {}),
    })
    if (error) return { error: await localizeChaseError(error.message) }
    revalidatePath(`/customers/${customerId}`)
    return { success: true }
}
