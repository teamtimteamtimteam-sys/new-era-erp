'use server'

// 触发成本分摊:调用 DB 函数 allocate_processing_costs(默认基准 metal_value)。
// 该函数会写回加工单的成本合计/快照与各产出腿的分摊成本/单位成本。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '../../errorCodes'

export async function runAllocation(runId: string) {
    const supabase = await createClient()

    // 不传 p_basis —— 用服务端默认(metal_value)
    const { error } = await supabase.rpc('allocate_processing_costs', { p_run_id: runId })

    if (error) {
        return { error: await localizeProcessingError(error.message) }
    }

    revalidatePath(`/operation/processing/${runId}`)
    return {}
}
