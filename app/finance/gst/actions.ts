'use server'

// app/finance/gst/actions.ts
// GST 期间的三个动作。校验【全部】在数据库里 —— 页面不重复判断一遍
// (页面与服务端各写一份同一条规矩,是本仓库付过四次账的形状)。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../financeErrorCodes'

export async function openGstPeriod(periodStart: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 期末由数据库按季推;这里只传期初,少一个可以填错的格子。
    const start = new Date(periodStart + 'T00:00:00Z')
    const end = new Date(Date.UTC(start.getUTCFullYear(), start.getUTCMonth() + 3, 0))
    const { error } = await supabase.rpc('open_gst_period', {
        p_period_start: periodStart,
        p_period_end: end.toISOString().slice(0, 10),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    revalidatePath('/finance/gst')
    return {}
}

export async function fileGstReturn(
    periodId: string, filedOn: string, reference: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    // 【申报日必填,且不给默认值】它决定这份记录说的是哪一天报的 ——
    // 一个 CURRENT_DATE 默认会把"忘了填"悄悄变成"今天报的"(FIN-10 那一课)。
    // 没填就【干脆不传】,由数据库那条具名拒绝答话(GST_FILED_DATE_REQUIRED)。
    // 送 '' 会在 cast 成 date 时炸出一个没有名字的错;在这里先判一次空,
    // 又成了同一条规矩的第二处实现 —— 两者都不要,所以 fu2 给参数加了 DEFAULT NULL。
    const { error } = await supabase.rpc('file_gst_return', {
        p_period_id: periodId,
        ...(filedOn ? { p_filed_on: filedOn } : {}),
        ...(reference.trim() ? { p_reference: reference.trim() } : {}),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    revalidatePath('/finance/gst')
    revalidatePath(`/finance/gst/${periodId}`)
    return {}
}

export async function correctGstReturn(
    periodId: string, reason: string
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('correct_gst_return', {
        p_original_period_id: periodId,
        p_reason: reason.trim(),
    })
    if (error) return { error: await localizeFinanceError(error.message) }
    revalidatePath('/finance/gst')
    return {}
}
