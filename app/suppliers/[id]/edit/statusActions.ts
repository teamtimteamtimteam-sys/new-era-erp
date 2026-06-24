'use server'

import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { revalidatePath } from 'next/cache'

export type ChangeStatusState = {
    error?: string
    success?: boolean
}

export async function changeSupplierStatus(
    id: string,
    newStatus: Database['public']['Enums']['supplier_status']
): Promise<ChangeStatusState> {
    const supabase = await createClient()

    const { error } = await supabase
        .from('suppliers')
        .update({ status: newStatus })
        .eq('id', id)
        .is('deleted_at', null)

    if (error) {
        return { error: `状态变更失败: ${error.message}` }
    }

    revalidatePath('/suppliers')
    revalidatePath(`/suppliers/${id}/edit`)
    return { success: true }
}