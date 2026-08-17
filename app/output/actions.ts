'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { localizeDeletionError } from '@/app/components/inventory/deletionErrorCodes'
import { isStockErrorCode, localizeStockError } from '@/app/components/inventory/stockErrorCodes'

// AUDEL-1b:理由【必填】,而【录入框是 AUDEL-2】。
// 在那之前,界面传空串 → 数据库按名拒 → 屏幕上是一句看得懂的"请填写理由"。
// 这是刻意的:一个大声拒绝的按钮,好过一个悄悄写下空理由的按钮。
export async function softDeleteOutput(id: string, reason: string = '') {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    void user
    const { error } = await supabase.rpc('soft_delete_output_batch', {
        p_batch_id: id,
        p_reason: reason,
    })

    if (error) {
        // SO-2:注销可能撞上一条【库存那一族】的具名拒绝(货还许着人)。
        // 判据是那个集合本身,不是在这里手抄一句正则(IOD-2-fu1 的教训);
        // 不归它管的错误照旧包进 output.deleteError,原样可见。
        if (isStockErrorCode(error.message)) {
            return { error: await localizeStockError(error.message) }
        }
        return { error: await localizeDeletionError(error.message) }
    }

    revalidatePath('/output')
    return { success: true }
}
