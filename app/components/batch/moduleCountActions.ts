'use server'

// MES-5a-1(2026-10-08,规格 §3.1;MES-5a Step 0 Q4,Tim):在批次页上补或改一批的模组数 —— 进料批与产出批共用这一扇门(set_batch_module_count)。
//   码:那个模块的编辑码,或 action.processing_commit(放电站台的操作员);适用性、"不少于已有结论的模组数"与"核实之后锁住"都由库里的守卫判 ——
//   这里只把拒绝说成人话(加工那一支收着这几句)。空 = 清掉(回到"没记")。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '@/app/operation/errorCodes'

export async function setBatchModuleCount(kind: 'inbound' | 'output', batchId: string, raw: string): Promise<{ error?: string }> {
    const v = raw.trim()
    const count = v === '' ? null : Number(v)
    // 写不成整数的不能送过去:JSON 里 NaN 就是 null,而 null 的意思是"清掉" —— 一个打错的数会悄悄抹掉原值。按库里那条码说出来。
    if (count !== null && !Number.isInteger(count)) return { error: await localizeProcessingError(`MODULE_COUNT_INVALID|${v}`) }
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_batch_module_count', {
        p_kind: kind, p_batch_id: batchId, p_count: count as number,   // null = 清掉
    })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(kind === 'inbound' ? `/inbound/${batchId}/edit` : `/output/${batchId}/edit`)
    return {}
}
