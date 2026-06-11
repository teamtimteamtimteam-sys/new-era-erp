'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'

export async function addCompliance(supplierId: string, formData: FormData) {
    const cert_type = (formData.get('cert_type') as string)?.trim()
    const cert_no = (formData.get('cert_no') as string)?.trim() || null
    const issuing_body = (formData.get('issuing_body') as string)?.trim() || null
    const valid_from = (formData.get('valid_from') as string)?.trim() || null
    const valid_until = (formData.get('valid_until') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    if (!cert_type) {
        return { error: '证书类型是必填的' }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('supplier_compliance').insert({
        supplier_id: supplierId,
        cert_type,
        cert_no,
        issuing_body,
        valid_from: valid_from || null,
        valid_until: valid_until || null,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
    })

    if (error) {
        return { error: `添加失败: ${error.message}` }
    }

    revalidatePath(`/suppliers/${supplierId}/edit`)
    return { success: true }
}

export async function deleteCompliance(complianceId: string, supplierId: string) {
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('supplier_compliance')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', complianceId)
        .is('deleted_at', null)

    if (error) {
        return { error: `删除失败: ${error.message}` }
    }

    revalidatePath(`/suppliers/${supplierId}/edit`)
    return { success: true }
}
