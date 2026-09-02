'use server'

// app/settings/accounts/inviteActions.ts
// 账号邀请。【只在服务端跑】—— 'use server' 保证这个模块不会进浏览器包,
// 而它引入的 lib/supabase/admin.ts 里的 import 'server-only' 会让任何
// 客户端引用在【构建期】就失败。
//
// 流程:发邀请 → 拿到新账号的 user_id → 关联员工档案 → 授予角色。
// 后两步经 cut 3 / cut 4 的 SECURITY DEFINER 函数,所以最后一个管理员守卫、
// edit-蕴含-view、已被关联的员工等等一律照常生效。
import { revalidatePath } from 'next/cache'
import { headers } from 'next/headers'
import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { canManagePermissions } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'

export type InviteState = { error?: string; success?: boolean; email?: string }

async function localize(message: string): Promise<string> {
    const t = await getTranslations()
    const m = (message ?? '').trim().match(/([A-Z_]+)(?:\|(.*))?$/)
    if (!m) return message
    switch (m[1]) {
        case 'PERMISSION_DENIED':
            return t('permissions.errDenied')
        case 'EMPLOYEE_ALREADY_LINKED':
            return t('permissions.errEmployeeLinked', { 0: m[2] ?? '' })
        case 'LAST_ADMIN_PROTECTED':
            return t('permissions.errLastAdmin')
        case 'EDIT_REQUIRES_VIEW':
            return t('permissions.errEditRequiresView', { 0: m[2] ?? '' })
        default:
            return message
    }
}

async function redirectBase(): Promise<string> {
    const h = await headers()
    const proto = h.get('x-forwarded-proto') ?? 'https'
    const host = h.get('host') ?? 'localhost:3000'
    return `${proto}://${host}`
}

export async function inviteUser(form: {
    email: string
    employeeId: string | null
    roleIds: string[]
}): Promise<InviteState> {
    // 【第三道防线】即便有人绕过导航与页面守卫直接调这个 action,这里再查一次。
    if (!(await canManagePermissions())) {
        const t = await getTranslations()
        return { error: t('permissions.errDenied') }
    }

    const email = form.email.trim().toLowerCase()
    if (!email) {
        const t = await getTranslations()
        return { error: t('permissions.errEmailRequired') }
    }

    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }

    const { data, error } = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo: `${await redirectBase()}/set-password`,
    })
    if (error) return { error: error.message }

    const userId = data?.user?.id
    if (!userId) {
        const t = await getTranslations()
        return { error: t('permissions.errInviteNoUser') }
    }

    // 关联与授权走普通的 anon 客户端 + DEFINER 函数 —— 【不用 service role】,
    // 这样 action.manage_permissions 与各个守卫仍然是真的在把关。
    const supabase = await createClient()

    if (form.employeeId) {
        const { error: linkErr } = await supabase.rpc('set_user_employee_link', {
            p_user_id: userId,
            p_employee_id: form.employeeId,
        })
        if (linkErr) return { error: await localize(linkErr.message) }
    }

    if (form.roleIds.length > 0) {
        const { error: roleErr } = await supabase.rpc('set_user_roles', {
            p_user_id: userId,
            p_role_ids: form.roleIds,
        })
        if (roleErr) return { error: await localize(roleErr.message) }
    }

    revalidatePath('/settings/accounts')
    return { success: true, email }
}

// 重发邀请:同一个入口,Supabase 会重新发一封邮件给尚未确认的账号。
export async function resendInvite(email: string): Promise<InviteState> {
    if (!(await canManagePermissions())) {
        const t = await getTranslations()
        return { error: t('permissions.errDenied') }
    }
    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }
    const { error } = await admin.auth.admin.inviteUserByEmail(email, {
        redirectTo: `${await redirectBase()}/set-password`,
    })
    if (error) return { error: error.message }
    revalidatePath('/settings/accounts')
    return { success: true, email }
}

// 关联/解绑,供用户页的编辑面板使用 —— 换掉 cut 3 那段两条语句的写法。
export async function setEmployeeLink(
    userId: string,
    employeeId: string | null
): Promise<InviteState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('set_user_employee_link', {
        p_user_id: userId,
        p_employee_id: employeeId ?? undefined,
    })
    if (error) return { error: await localize(error.message) }
    revalidatePath('/settings/accounts')
    return { success: true }
}
