'use server'

import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { revalidatePath } from 'next/cache'
import { refuseFromCoded } from '@/lib/action-refusal'
import { localizeSupplierError } from '@/app/suppliers/supplierErrorCodes'

export type ChangeStatusState = {
    error?: string
    /** ALERT-1:降级后的数据库原文 —— 永远不做标题。 */
    detail?: string
    success?: boolean
}

// ★ ROLE-1 Batch 2a(Tim,Batch 2a grilling Q2):供应商状态只有一扇门 —— set_supplier_status。
//   此前这里是一句直连 UPDATE suppliers.status;现在那句会被 guard_supplier_direct_write
//   按名拒(SUPPLIER_STATUS_THROUGH_FUNCTION_ONLY)。函数自己做四件事:合不合法
//   (supplier_status_moves)、这一步要哪个码(CFO 的 action.supplier_approve 或 suppliers.edit)、
//   建档人不能批自己建的(按人认)、以及留痕(approval_log + supplier_status_history)。
//   ☞ 不再需要"零行 = 没改成"那一支:函数要么改成、要么抛,没有安静的第三种结局。
export async function changeSupplierStatus(
    id: string,
    newStatus: Database['public']['Enums']['supplier_status']
): Promise<ChangeStatusState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('set_supplier_status', {
        p_supplier_id: id,
        p_to: newStatus,
    })

    if (error) {
        // refuseFromCoded 的三支分支:① PERMISSION_DENIED(那一步要的码)先接;
        // ② 本地化器认出供应商那几条码(跳转不合法、自批、直连被拒)→ 人话;
        // ③ 都不是 → 原文降级进 detail。
        return await refuseFromCoded(error.message, localizeSupplierError)
    }

    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    return { success: true }
}
