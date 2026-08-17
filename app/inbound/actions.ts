'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeDeletionError } from '@/app/components/inventory/deletionErrorCodes'

// AUDEL-1b:理由【必填】,而【录入框是 AUDEL-2】。
// 在那之前,界面传空串 → 数据库按名拒 → 屏幕上是一句看得懂的"请填写理由"。
// 这是刻意的:一个大声拒绝的按钮,好过一个悄悄写下空理由的按钮。
export async function softDeleteInbound(id: string, reason: string = '') {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    // 【直连 UPDATE 那条路已经被守卫堵死】(AUDEL-1b)—— 软删只能走这扇门,
    // 它会把 deleted_by(会话里的人)与 delete_reason 一起写下去。
    void user
    const { error } = await supabase.rpc('soft_delete_inbound_batch', {
        p_batch_id: id,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeDeletionError(error.message) }
    }

    revalidatePath('/inbound')
    return { success: true }
}
