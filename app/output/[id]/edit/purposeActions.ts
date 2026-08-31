'use server'

// PROC-WIRE-1A:设定 / 释放【下游工序投料】指定的服务端动作。
//
// 【为什么走 RPC 而不是直接 UPDATE 那一列】output_batches 的 UPDATE 策略要的是
// module.output.edit(销售/库存侧),而**把一批货许给产线是一个【工序】决定**。
// 直接改列会让这件事落在错的权限上。门(set_output_batch_purpose)里要的是
// module.processing.edit,与 loss_categories 同一条。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { PURPOSE_ERROR_CODES } from './purposeErrorCodes'

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

async function localize(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()
    const m = raw.match(CODE_RE)
    // 不在集合里的原样返回 —— 看得见才修得掉(IOD-1b 的教训)。
    if (!m || !PURPOSE_ERROR_CODES.has(m[1])) return raw
    const params: Record<string, string> = {}
    if (m[2]) m[2].split('|').forEach((v, i) => { params[String(i)] = v })
    return t('output.purpose.errors.' + m[1], params)
}

// PROC-WIRE-1B-ii(R3):第三个参数是【在等哪一道工序】。
// 【为什么与用途走同一扇门】"许给产线"与"许给产线的哪一台"是同一个工序决定;
// 拆成两次调用会让中间那一刻既是投料、又不知道等谁,而且两扇门就是两处权限判断。
// 【释放指定时它由门自己清掉】—— 不是调用者要记得的一步(见门里的注释)。
export async function setOutputBatchPurpose(
    batchId: string,
    purposeCode: string,
    awaitingOperationCode?: string | null
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_output_batch_purpose', {
        p_output_batch_id: batchId,
        p_purpose_code: purposeCode,
        // 【清空传 undefined,不传 null】生成的类型把这个可选参数标成
        // string | undefined;省略它时 PostgREST 不发这个字段,于是函数体里
        // 那个 DEFAULT NULL 生效 —— 与"显式传 NULL"是同一个结果。
        p_awaiting_operation_type_code: awaitingOperationCode ?? undefined,
    })
    if (error) return { error: await localize(error.message) }
    revalidatePath(`/output/${batchId}/edit`)
    revalidatePath('/output')
    return {}
}
