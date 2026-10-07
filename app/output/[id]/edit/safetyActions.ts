'use server'

// MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q23,Tim):产出批的安全状态 —— 从此只经 set_output_safety_states 写。
//   此前这里从浏览器直连 insert / delete 那张表(删 = 硬删,没有理由、没有墓碑);那两条写策略已拿掉,
//   直连写在库里按名拒(SAFETY_STATES_THROUGH_FUNCTION_ONLY)。现在:记一条 = 把它加进这一批此刻的整组;
//   拿掉一条 = 【结束】它,要一个理由(SAFETY_STATE_END_REASON_REQUIRED);没变的那几条一个字节都不动(滞留时钟不重来)。
//   拒绝走材料那一族的映射(状态码与这几条拒绝本来就在那里说人话)。

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { localizeMaterialError } from '@/app/materials/materialErrorCodes'

export async function setOutputSafetyStates(
    batchId: string,
    codes: string[],
    endReason?: string,
): Promise<{ error?: string }> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_output_safety_states', {
        p_output_batch_id: batchId,
        p_codes: codes,
        ...(endReason !== undefined ? { p_end_reason: endReason } : {}),
    })
    if (error) return { error: await localizeMaterialError(error.message) }
    revalidatePath(`/output/${batchId}/edit`)
    return {}
}
