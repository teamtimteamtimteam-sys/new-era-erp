'use server'

import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export async function addCompliance(supplierId: string, formData: FormData) {
    const t = await getTranslations()
    // CMP-1:类型是 certificate_types 的码,不再是自由文本 —— 自由文本让
    // "按类型定处置"无从谈起(article 18 / Art. 18 / 其他 全都合法)。
    const cert_type_code = (formData.get('cert_type_code') as string)?.trim()
    // 证书文件:引用本供应商已上传的附件(可选)。补上外键之后,证书记录
    // 从此能走到证书本身 —— 此前 document_id 有名无实,无外键也无人写入。
    const document_id = (formData.get('document_id') as string)?.trim() || null
    const cert_no = (formData.get('cert_no') as string)?.trim() || null
    const issuing_body = (formData.get('issuing_body') as string)?.trim() || null
    const valid_from = (formData.get('valid_from') as string)?.trim() || null
    const valid_until = (formData.get('valid_until') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    if (!cert_type_code) {
        return { error: t('suppliers.compliance.errCertType') }
    }

    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('supplier_compliance').insert({
        supplier_id: supplierId,
        cert_type_code,
        document_id,
        cert_no,
        issuing_body,
        valid_from: valid_from || null,
        valid_until: valid_until || null,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
    })

    if (error) {
        return { error: t('suppliers.compliance.addError', { message: error.message }) }
    }

    revalidatePath(`/suppliers/${supplierId}/edit`)
    return { success: true }
}

export async function deleteCompliance(complianceId: string, supplierId: string) {
    const t = await getTranslations()
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
        return { error: t('suppliers.compliance.deleteError', { message: error.message }) }
    }

    revalidatePath(`/suppliers/${supplierId}/edit`)
    return { success: true }
}
