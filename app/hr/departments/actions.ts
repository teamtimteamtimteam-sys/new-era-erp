'use server'

// 部门的增/改/软删。环路由 DB 触发器把关(DEPARTMENT_CYCLE),表单另外在服务端
// 把自己与自己的所有下级从上级下拉里剔掉 —— 让人先根本选不到,而不是选了再报错。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { localizeHrError } from '../hrErrorCodes'

export type DepartmentFormState = { error?: string }

export async function saveDepartment(
    _prevState: DepartmentFormState,
    formData: FormData
): Promise<DepartmentFormState> {
    const t = await getTranslations()

    const id = String(formData.get('department_id') ?? '').trim()
    const code = String(formData.get('code') ?? '').trim()
    const nameEn = String(formData.get('name_en') ?? '').trim()
    const nameZh = String(formData.get('name_zh') ?? '').trim()
    const parentRaw = String(formData.get('parent_department_id') ?? '').trim()
    const isActive = formData.get('is_active') === 'on'
    const notes = String(formData.get('notes') ?? '').trim()

    if (!code) return { error: t('hr.errCodeRequired') }
    if (!nameEn || !nameZh) return { error: t('hr.errNameRequired') }

    const supabase = await createClient()
    const payload = {
        code,
        name_en: nameEn,
        name_zh: nameZh,
        parent_department_id: parentRaw || null,
        is_active: isActive,
        notes: notes || null,
    }

    const { error } = id
        ? await supabase.from('departments').update(payload).eq('id', id)
        : await supabase.from('departments').insert(payload)

    if (error) {
        if (error.code === '23505') return { error: t('hr.errCodeTaken', { 0: code }) }
        return { error: await localizeHrError(error.message) }
    }

    revalidatePath('/hr/departments')
    redirect('/hr/departments')
}

// 软删:先数在册员工 —— 部门还有人时给一句人话,而不是把外键报错甩到脸上
export async function deleteDepartment(departmentId: string): Promise<{ error?: string }> {
    const t = await getTranslations()
    const supabase = await createClient()

    const { count } = await supabase
        .from('employees')
        .select('id', { count: 'exact', head: true })
        .eq('department_id', departmentId)
        .is('deleted_at', null)

    if ((count ?? 0) > 0) {
        return { error: t('hr.deptHasEmployees', { n: count ?? 0 }) }
    }

    const { error } = await supabase
        .from('departments')
        .update({ deleted_at: new Date().toISOString() })
        .eq('id', departmentId)
    if (error) return { error: await localizeHrError(error.message) }

    revalidatePath('/hr/departments')
    return {}
}
