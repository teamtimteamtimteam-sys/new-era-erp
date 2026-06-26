'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'

const VALID_STATUSES = ['todo', 'in_progress', 'done'] as const
type TaskStatus = (typeof VALID_STATUSES)[number]

export async function updateTaskStatus(id: string, newStatus: string) {
    if (!VALID_STATUSES.includes(newStatus as TaskStatus)) {
        return { error: `Invalid status: ${newStatus}` }
    }

    const supabase = await createClient()

    const { error } = await supabase
        .from('tasks')
        .update({ status: newStatus })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不动

    if (error) {
        return { error: error.message }
    }

    revalidatePath('/tasks')
    return { success: true }
}
