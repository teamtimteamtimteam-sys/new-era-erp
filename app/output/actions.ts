'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'
import { isStockErrorCode, localizeStockError } from '@/app/components/inventory/stockErrorCodes'

export async function softDeleteOutput(id: string) {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('output_batches')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        // SO-2:注销可能撞上一条【库存那一族】的具名拒绝(货还许着人)。
        // 判据是那个集合本身,不是在这里手抄一句正则(IOD-2-fu1 的教训);
        // 不归它管的错误照旧包进 output.deleteError,原样可见。
        if (isStockErrorCode(error.message)) {
            return { error: await localizeStockError(error.message) }
        }
        return { error: t('output.deleteError', { message: error.message }) }
    }

    revalidatePath('/output')
    return { success: true }
}
