'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type CreateMaterialState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createMaterial(
    _prevState: CreateMaterialState,
    formData: FormData
): Promise<CreateMaterialState> {
    // 1. 取字段
    const name = (formData.get('name') as string)?.trim()
    const category = (formData.get('category') as string)?.trim()
    const chemistry = (formData.get('chemistry') as string)?.trim() || null
    const unit = (formData.get('unit') as string)?.trim() || 'kg'
    const spec = (formData.get('spec') as string)?.trim() || null
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!name) fieldErrors.name = '名称是必填的'
    if (!category) fieldErrors.category = '类别是必填的'

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('materials').insert({
        name,
        category,
        chemistry,
        unit,
        spec,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // code 不传,用触发器自动生成
        // status 不传,用数据库默认值 'draft'
    } as InsertRow<'materials'>)

    if (error) {
        return { error: `保存失败: ${error.message}` }
    }

    revalidatePath('/materials')
    redirect('/materials')
}
