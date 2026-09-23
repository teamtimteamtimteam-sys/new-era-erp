'use server'

// app/settings/accountsActions.ts
// 权限管理的写入口。全部走 cut 3 的两个 SECURITY DEFINER 函数,
// 界面这边【不直接写 user_roles / role_permissions】—— 那两张表的守卫
// (最后一个管理员、edit 蕴含 view、系统角色保护)都长在函数里。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { fallbackForRawError } from '@/lib/machine-text'

export type ActionState = { error?: string; success?: boolean }

// DB 抛出来的码 → 人话。【不要把码摔到用户脸上】:看见 LAST_ADMIN_PROTECTED 的人
// 正处在"我刚把自己锁出去了吗"的时刻,那一刻他要的是一句解释。
async function localize(message: string): Promise<string> {
    const t = await getTranslations()
    const raw = (message ?? '').trim()
    const code = raw.match(/([A-Z_]+)(?:\|(.*))?$/)
    if (!code) return await fallbackForRawError(raw, 'localize@app/settings/accountsActions.ts')
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
        // ── APR-ROUTE-1 Batch B(R3):额外账号那一块控件的拒绝 ──
        case 'ADDITIONAL_NEEDS_PRIMARY':
            return t('permissions.errAdditionalNeedsPrimary', { 0: code[2] ?? '' })
        case 'ACCOUNT_IS_PRIMARY':
            return t('permissions.errAccountIsPrimary', { 0: code[2] ?? '' })
        case 'ACCOUNT_ALREADY_ADDITIONAL':
            return t('permissions.errAccountAlreadyAdditional', { 0: code[2] ?? '' })
        case 'ACCOUNT_IS_ADDITIONAL':
            return t('permissions.errAccountIsAdditional', { 0: code[2] ?? '' })
        case 'ACCOUNT_HAS_DECISIONS':
            return t('permissions.errAccountHasDecisions', { 0: code[2] ?? '' })
        case 'ACCOUNT_NOT_ADDITIONAL':
            return t('permissions.errAccountNotAdditional')
        case 'ROLE_NOT_FOUND':
            return t('permissions.errRoleNotFound')
        case 'PERMISSION_NOT_FOUND':
            return t('permissions.errPermissionNotFound', { 0: code[2] ?? '' })
        default:
            return await fallbackForRawError(raw, 'localize@app/settings/accountsActions.ts')
    }
}

export async function saveUserRoles(
    userId: string,
    roleIds: string[],
    reason: string | null,
    employeeId: string | null,
    /**
     * ★ APR-ROUTE-1 Batch B(R3):这一行是某人的【额外账号】时为 true。
     *   额外账号的"属于谁"由 link/unlink 那一块控件管;在这里再调一次
     *   set_user_employee_link 会试图把它设成那个人的【主账号】,而那会被
     *   ACCOUNT_IS_ADDITIONAL 拒掉 —— 保存角色这件事于是整个失败。
     */
    isAdditional = false
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
    if (!isAdditional) {
        const { error: linkErr } = await supabase.rpc('set_user_employee_link', {
            p_user_id: userId,
            p_employee_id: employeeId ?? undefined,
        })
        if (linkErr) return { error: await localize(linkErr.message) }
    }

    revalidatePath('/settings/accounts')
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
    revalidatePath('/settings/roles')
    revalidatePath('/settings/reference')
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
    revalidatePath('/settings/roles')
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
    revalidatePath('/settings/roles')
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
    revalidatePath('/settings/roles')
    return { success: true }
}

// ── APR-ROUTE-1 Batch B(Tim 的 R3 · Q9 · Q2):一个人的【额外账号】 ─────────────
// 两支都只是把 RPC 的答案原样带回来:闸(action.manage_permissions)、
// "做过决定的账号不许链"(Q1)与链接史(Q2)全都长在函数里,屏幕不做第二份判断。

export async function linkAdditionalAccount(userId: string, employeeId: string): Promise<ActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('link_additional_account', {
        p_user_id: userId,
        p_employee_id: employeeId,
    })
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/accounts')
    return { success: true }
}

export async function unlinkAdditionalAccount(userId: string): Promise<ActionState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('unlink_additional_account', { p_user_id: userId })
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/accounts')
    return { success: true }
}
