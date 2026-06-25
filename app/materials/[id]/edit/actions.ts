'use server'

import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { getTranslations } from '@/lib/i18n/server'

export type UpdateMaterialState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateMaterial(
    id: string,
    _prevState: UpdateMaterialState,
    formData: FormData
): Promise<UpdateMaterialState> {
    const t = await getTranslations()

    // 1. 取字段
    const name = (formData.get('name') as string)?.trim()
    const category = (formData.get('category') as string)?.trim()
    const chemistry = (formData.get('chemistry') as string)?.trim() || null
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const spec = (formData.get('spec') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!name) fieldErrors.name = t('materials.form.errName')
    if (!category) fieldErrors.category = t('materials.form.errCategory')

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 更新数据库(不更新 code 和 status)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('materials')
        .update({
            name,
            category,
            chemistry,
            unit,
            spec,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        return { error: t('materials.form.saveError', { message: error.message }) }
    }

    revalidatePath('/materials')
    revalidatePath(`/materials/${id}/edit`)
    redirect('/materials')
}
