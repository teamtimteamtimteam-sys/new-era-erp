'use server'

// MES-4b(2026-10-07,规格 §3.4;MES-4b Step 0 Q4 · Q7,Tim):在批次页上补或改电芯结构 —— 进料批与产出批共用这一扇门(set_batch_cell_construction)。
//   码:那个模块的编辑码,或 action.processing_commit(站台的操作员);适用性与"喂过一张已提交的单之后锁住"都由库里的守卫判 ——
//   这里只把拒绝说成人话(加工那一支收着这几句)。空 = 清掉(回到"没记")。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeProcessingError } from '@/app/operation/errorCodes'

export async function setBatchCellConstruction(kind: 'inbound' | 'output', batchId: string, code: string): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_batch_cell_construction', { p_kind: kind, p_batch_id: batchId, p_code: code })
    if (error) return { error: await localizeProcessingError(error.message) }
    revalidatePath(kind === 'inbound' ? `/inbound/${batchId}/edit` : `/output/${batchId}/edit`)
    return {}
}
