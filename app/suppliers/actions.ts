'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'

export async function softDeleteSupplier(id: string) {
    const supabase = await createClient()

    const { error } = await supabase
        .from('suppliers')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        return { error: `删除失败: ${error.message}` }
    }

    revalidatePath('/suppliers')
    return { success: true }
}