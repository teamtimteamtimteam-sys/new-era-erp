'use server'

// PARTY-1:联系人的服务端动作。写入只经 save_counterparty_contact(SECURITY DEFINER)——
// 那张表没有 INSERT/UPDATE 策略,理由写在函数抬头(设主联系人要在同一笔事务里撤旧的)。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { localizeContactError } from './contactErrorCodes'

export type ContactState = { error?: string; success?: boolean }

export async function saveContact(input: {
    customerId?: string; supplierId?: string; contactId?: string
    name: string; role: string; email: string; phone: string; notes: string
    isPrimary: boolean
}): Promise<ContactState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('save_counterparty_contact', {
        p_customer_id: input.customerId ?? undefined,
        p_supplier_id: input.supplierId ?? undefined,
        p_contact_id: input.contactId ?? undefined,
        p_name: input.name,
        p_role: input.role || undefined,
        p_email: input.email || undefined,
        p_phone: input.phone || undefined,
        p_notes: input.notes || undefined,
        p_is_primary: input.isPrimary,
    })
    if (error) return { error: await localizeContactError(error.message) }
    if (input.customerId) {
        revalidatePath(`/sales/customers/${input.customerId}`)
        revalidatePath('/sales/customers')
    }
    if (input.supplierId) revalidatePath(`/suppliers/${input.supplierId}/edit`)
    return { success: true }
}

// 【软删,不真删】一个联系人被删掉之后,历史上"我们那天联系的是他"仍然成立 ——
// collection_chases 把名字【抄成文本】正是为了这个,而这里保留行是为了
// 「这个人还在不在名单上」与「这个人从来不存在」分得开。
export async function removeContact(input: {
    contactId: string; customerId?: string; supplierId?: string
}): Promise<ContactState> {
    const supabase = await createClient()
    // 【走函数,不直连 UPDATE】本表没有 UPDATE 策略 —— 见 soft_delete 那支函数的抬头:
    // 为软删开一条 UPDATE 策略会把 is_primary 一起开出去。
    const { error } = await supabase.rpc('soft_delete_counterparty_contact', {
        p_contact_id: input.contactId,
    })
    if (error) return { error: await localizeContactError(error.message) }
    if (input.customerId) {
        revalidatePath(`/sales/customers/${input.customerId}`)
        revalidatePath('/sales/customers')
    }
    if (input.supplierId) revalidatePath(`/suppliers/${input.supplierId}/edit`)
    return { success: true }
}
