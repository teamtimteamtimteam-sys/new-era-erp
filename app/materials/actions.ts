'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export async function softDeleteMaterial(id: string) {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('materials')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        return { error: t('materials.deleteError', { message: error.message }) }
    }

    revalidatePath('/materials')
    return { success: true }
}
