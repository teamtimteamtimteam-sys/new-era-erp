'use server'

// app/settings/permissions/actions.ts
// 权限管理的写入口。全部走 cut 3 的两个 SECURITY DEFINER 函数,
// 界面这边【不直接写 user_roles / role_permissions】—— 那两张表的守卫
// (最后一个管理员、edit 蕴含 view、系统角色保护)都长在函数里。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'

export type ActionState = { error?: string; success?: boolean }

// DB 抛出来的码 → 人话。【不要把码摔到用户脸上】:看见 LAST_ADMIN_PROTECTED 的人
// 正处在"我刚把自己锁出去了吗"的时刻,那一刻他要的是一句解释。
async function localize(message: string): Promise<string> {
    const t = await getTranslations()
    const raw = (message ?? '').trim()
    const code = raw.match(/([A-Z_]+)(?:\|(.*))?$/)
    if (!code) return raw
    switch (code[1]) {
        case 'LAST_ADMIN_PROTECTED':
            return t('permissions.errLastAdmin')
        case 'PERMISSION_DENIED':
            return t('permissions.errDenied')
        case 'EDIT_REQUIRES_VIEW':
            return t('permissions.errEditRequiresView', { 0: code[2] ?? '' })
        case 'SYSTEM_ROLE_PROTECTED':
            return t('permissions.errSystemRole')
        case 'EMPLOYEE_ALREADY_LINKED':
            return t('permissions.errEmployeeLinked', { 0: code[2] ?? '' })
        case 'EMPLOYEE_NOT_FOUND':
            return t('permissions.errEmployeeNotFound')
        case 'ROLE_NOT_FOUND':
            return t('permissions.errRoleNotFound')
        case 'PERMISSION_NOT_FOUND':
            return t('permissions.errPermissionNotFound', { 0: code[2] ?? '' })
        default:
            return raw
    }
}

export async function saveUserRoles(
    userId: string,
    roleIds: string[],
    reason: string | null,
    employeeId: string | null
): Promise<ActionState> {
    const supabase = await createClient()

    const { error } = await supabase.rpc('set_user_roles', {
        p_user_id: userId,
        p_role_ids: roleIds,
        p_reason: reason && reason.trim() !== '' ? reason.trim() : undefined,
    })
    if (error) return { error: await localize(error.message) }

    // cut 4:关联走 set_user_employee_link —— 解绑旧的与绑上新的在【一次调用】里
    // 同生共死。cut 3 这里是两条独立语句,中间失败会让账号谁也不关联。
    const { error: linkErr } = await supabase.rpc('set_user_employee_link', {
        p_user_id: userId,
        p_employee_id: employeeId ?? undefined,
    })
    if (linkErr) return { error: await localize(linkErr.message) }

    revalidatePath('/settings/permissions')
    return { success: true }
}

export async function saveRolePermissions(
    roleId: string,
    codes: string[]
): Promise<ActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_role_permissions', {
        p_role_id: roleId,
        p_permission_codes: codes,
    })
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/permissions/roles')
    revalidatePath('/settings/permissions/reference')
    return { success: true }
}

export async function createRole(form: {
    code: string
    name_en: string
    name_zh: string
    description_en: string | null
    description_zh: string | null
    sort_order: number
}): Promise<ActionState & { roleId?: string }> {
    const supabase = await createClient()
    const { data, error } = await supabase
        .from('roles')
        .insert({ ...form })
        .select('id')
        .single()
    if (error) return { error: error.message }
    revalidatePath('/settings/permissions/roles')
    return { success: true, roleId: data?.id }
}

export async function updateRole(
    roleId: string,
    form: {
        name_en: string
        name_zh: string
        description_en: string | null
        description_zh: string | null
        is_active: boolean
        sort_order: number
    }
): Promise<ActionState> {
    const supabase = await createClient()
    // code 不在这里 —— 它是稳定标识,建成之后不改(见表单里的说明)
    const { error } = await supabase.from('roles').update(form).eq('id', roleId)
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/permissions/roles')
    return { success: true }
}

export async function softDeleteRole(roleId: string): Promise<ActionState> {
    const supabase = await createClient()
    // is_system 由 cut 1 的 guard_system_role 触发器挡住,这里不重复判断 ——
    // 重复的检查会漂移,数据库那一道不会。
    const { error } = await supabase
        .from('roles')
        .update({ deleted_at: new Date().toISOString(), is_active: false })
        .eq('id', roleId)
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/permissions/roles')
    return { success: true }
}
