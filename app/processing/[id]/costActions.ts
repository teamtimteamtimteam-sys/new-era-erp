'use server'

// 加工成本条目的服务端动作。add 绑定 runId;update/delete 只拿 entryId,内部反查 run_id。
// 只有【已提交且未软删除】的加工单才能增删改成本(reversed 单是历史,不可改)。
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { COST_TYPE_VALUES } from './costTypes'

type ParsedCost =
    | { cost_type: string; amount_usd: number; is_estimate: boolean; notes: string | null }
    | { error: string }

// 解析 + 校验表单:cost_type ∈ 集合;amount 为有限数(允许负数 —— 副产/处置抵扣);notes 可空。
async function parseCostForm(formData: FormData): Promise<ParsedCost> {
    const t = await getTranslations()
    const cost_type = (formData.get('cost_type') as string)?.trim() || ''
    const amount_raw = (formData.get('amount_usd') as string) ?? ''
    const is_estimate =
        formData.get('is_estimate') === 'on' || formData.get('is_estimate') === 'true'
    const notes = (formData.get('notes') as string)?.trim() || null

    if (!COST_TYPE_VALUES.includes(cost_type)) return { error: t('processing.cost.errInvalid') }
    const amount = Number(amount_raw)
    if (amount_raw === '' || !Number.isFinite(amount)) {
        return { error: t('processing.cost.errInvalid') }
    }
    return { cost_type, amount_usd: amount, is_estimate, notes }
}

// 加工单是否可编辑成本:存在、未软删、status = 'committed'。
async function runEditable(
    supabase: Awaited<ReturnType<typeof createClient>>,
    runId: string
): Promise<boolean> {
    const { data } = await supabase
        .from('processing_runs')
        .select('status, deleted_at')
        .eq('id', runId)
        .maybeSingle()
    return !!data && data.deleted_at === null && data.status === 'committed'
}

export async function addCostEntry(runId: string, formData: FormData) {
    const t = await getTranslations()
    const parsed = await parseCostForm(formData)
    if ('error' in parsed) return { error: parsed.error }

    const supabase = await createClient()
    if (!(await runEditable(supabase, runId))) {
        return { error: t('processing.cost.errRunNotEditable') }
    }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('processing_cost_entries').insert({
        run_id: runId,
        cost_type: parsed.cost_type,
        amount_usd: parsed.amount_usd,
        is_estimate: parsed.is_estimate,
        notes: parsed.notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
    } as InsertRow<'processing_cost_entries'>)

    if (error) return { error: t('processing.cost.saveError', { message: error.message }) }

    revalidatePath(`/processing/${runId}`)
    return {}
}

export async function updateCostEntry(entryId: string, formData: FormData) {
    const t = await getTranslations()
    const parsed = await parseCostForm(formData)
    if ('error' in parsed) return { error: parsed.error }

    const supabase = await createClient()
    const { data: entry } = await supabase
        .from('processing_cost_entries')
        .select('run_id')
        .eq('id', entryId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!entry || !(await runEditable(supabase, entry.run_id))) {
        return { error: t('processing.cost.errRunNotEditable') }
    }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('processing_cost_entries')
        .update({
            cost_type: parsed.cost_type,
            amount_usd: parsed.amount_usd,
            is_estimate: parsed.is_estimate,
            notes: parsed.notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', entryId)
        .is('deleted_at', null)

    if (error) return { error: t('processing.cost.saveError', { message: error.message }) }

    revalidatePath(`/processing/${entry.run_id}`)
    return {}
}

export async function softDeleteCostEntry(entryId: string) {
    const t = await getTranslations()
    const supabase = await createClient()

    const { data: entry } = await supabase
        .from('processing_cost_entries')
        .select('run_id')
        .eq('id', entryId)
        .is('deleted_at', null)
        .maybeSingle()
    if (!entry || !(await runEditable(supabase, entry.run_id))) {
        return { error: t('processing.cost.errRunNotEditable') }
    }

    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('processing_cost_entries')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', entryId)
        .is('deleted_at', null)

    if (error) return { error: t('processing.cost.deleteError', { message: error.message }) }

    revalidatePath(`/processing/${entry.run_id}`)
    return {}
}
