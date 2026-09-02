'use server'

// PROC-BUILD-1:一张加工单上【分了类的那部分损耗】的服务端动作。
//
// 【loss_qty 这一列本刀一列都没动】—— 这里写的是 processing_run_losses,
// 那是另一张表。两者不必相等;分类之和【不许超过】 loss_qty,而那条判据
// 由数据库的 trg_processing_run_losses_within_total 执行,不由这里执行。
// 屏幕上校验一遍再交给数据库,是把同一条规则写两份 —— 而两份必然漂开。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

// 数据库抛出的具名拒绝。不在集合里的原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
import { LOSS_ERROR_CODES } from './lossErrorCodes'
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

async function localize(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const m = raw.match(CODE_RE)
    if (!m || !LOSS_ERROR_CODES.has(m[1])) return raw
    const params: Record<string, string> = {}
    if (m[2]) m[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('processing.loss.errors.' + m[1], params)
}

export async function saveRunLoss(runId: string, formData: FormData): Promise<{ error?: string }> {
    const t = await getTranslations()
    const code = (formData.get('loss_category_code') as string)?.trim() || ''
    const raw = (formData.get('quantity') as string) ?? ''
    const notes = (formData.get('notes') as string)?.trim() || null
    if (!code) return { error: t('processing.loss.errInvalid') }
    const qty = Number(raw)
    // 【> 0,不是 >= 0】一笔为零的损耗与"没有这一类"分不开,
    // 而后者由"没有这一行"表示 —— 数据库上的 CHECK 说的是同一句话。
    if (raw === '' || !Number.isFinite(qty) || qty <= 0) return { error: t('processing.loss.errInvalid') }

    const supabase = await createClient()
    const { error } = await supabase
        .from('processing_run_losses')
        .upsert({ run_id: runId, loss_category_code: code, quantity: qty, notes },
                { onConflict: 'run_id,loss_category_code' })
    if (error) return { error: await localize(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}

export async function deleteRunLoss(runId: string, code: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase
        .from('processing_run_losses')
        .delete()
        .eq('run_id', runId)
        .eq('loss_category_code', code)
    if (error) return { error: await localize(error.message) }
    revalidatePath(`/operation/processing/${runId}`)
    return {}
}
