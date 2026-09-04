'use server'

// app/settings/accounts/accountActions.ts
// ════════════════════════════════════════════════════════════════════════════
// C-1(2026-09-04):建账号 + 当场设初始密码。**取代了此前的邮件邀请流程。**
// ════════════════════════════════════════════════════════════════════════════
// 【为什么邀请那一套整个换掉,而不是并存】本系统【没有邮件服务】,也不在本刀里建。
//   inviteUserByEmail 在没有配 SMTP 时【安静地什么也不做】——
//   一个按下去没有反应的按钮,比一个不存在的按钮坏得多(Tim 的裁定 Q12)。
//   Tim 当面把初始密码交给本人,所以账号必须在建出来的那一刻就能登录。
//
// 【email_confirm: true 是这条路能走通的关键】没有邮件服务就没有人能点确认链接,
//   而未确认的账号在 real_role_grants 的四条判据里【不算一个真的持有人】——
//   也就是说它连"最后一个管理员"都顶不上(见 db/functions/real_role_grants.sql)。
//   所以这里必须直接把它标成已确认。
//
// 【必须换一次密码】user_metadata.must_change_password 由中间件强制执行
//   (lib/supabase/middleware.ts),由 /set-password 在改完密码的同一次调用里清掉。
//   不这么做的话,Tim 当面交出去的那个密码就是这个账号【永远】的密码,
//   而系统分辨不出"改过"和"没改过"。
//
// ★★【密码只走一个方向:表单 → 这里 → Supabase】★★
//   它【不进】URL、不进任何 console/日志、不进任何被 git 跟踪的文件。
//   下面的错误分支一律不回显密码本身。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { createAdminClient } from '@/lib/supabase/admin'
import { canManagePermissions } from '@/lib/permissions'
import { getTranslations } from '@/lib/i18n/server'
// 【下限住在一个普通模块里,不在本文件】—— 'use server' 只许导出 async 函数。
import { MIN_PASSWORD_LENGTH } from '@/lib/passwordPolicy'

export type AccountState = { error?: string; success?: boolean; email?: string }

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

export async function createAccount(form: {
    email: string
    password: string
    roleId: string
    employeeId: string | null
}): Promise<AccountState> {
    const t = await getTranslations()

    // 【第三道防线】导航藏了入口、页面守卫拒了一次,这里再查一次 ——
    // 直接调这个 action 的人绕过了前两道。
    if (!(await canManagePermissions())) {
        return { error: t('permissions.errDenied') }
    }

    const email = form.email.trim().toLowerCase()
    if (!email) return { error: t('permissions.errEmailRequired') }

    // ★【没有角色就【拒绝建】,不默认给一个】★ 委托书点名的一条。
    //   默认一个角色等于替 Tim 做了一个他没有做的决定,而"给多了"是看不见的。
    if (!form.roleId) return { error: t('permissions.errRoleRequired') }

    if ((form.password ?? '').length < MIN_PASSWORD_LENGTH) {
        return { error: t('permissions.errPasswordTooShort', { 0: String(MIN_PASSWORD_LENGTH) }) }
    }

    let admin
    try {
        admin = createAdminClient()
    } catch (e) {
        return { error: e instanceof Error ? e.message : String(e) }
    }

    // 角色必须真的存在且在册 —— 在【建账号之前】问,这样失败时没有任何东西要清理。
    const supabase = await createClient()
    const { data: roleRow, error: roleErr } = await supabase
        .from('roles')
        .select('id')
        .eq('id', form.roleId)
        .is('deleted_at', null)
        .eq('is_active', true)
        .maybeSingle()
    if (roleErr) return { error: await localize(roleErr.message) }
    if (!roleRow) return { error: t('permissions.errRoleRequired') }

    const { data, error } = await admin.auth.admin.createUser({
        email,
        password: form.password,
        email_confirm: true,                       // 没有邮件服务,见抬头
        user_metadata: { must_change_password: true },
    })
    if (error) return { error: error.message }

    const userId = data?.user?.id
    if (!userId) return { error: t('permissions.errCreateNoUser') }

    // ════════════════════════════════════════════════════════════════════════
    // ★★【从这里开始,任何失败都必须【把账号删掉】—— 而删除本身要查状态码】★★
    //   PRE-ACCOUNT-1 的头条正是这个形状:四个带着仓库里公开密码的管理员账号
    //   活了 ~17.5 小时,因为建它们的脚本【清理失败了却没人知道】。
    //   所以下面这个 undo 返回它自己成不成功,而调用点把两种失败分开报:
    //   「建到一半失败了,已经清干净」 vs 「建到一半失败了,而且【没清掉】」。
    //   后者是一个必须有人立刻去看的状态,不能和前者说同一句话。
    // ════════════════════════════════════════════════════════════════════════
    const undo = async (reason: string): Promise<AccountState> => {
        const { error: delErr } = await admin.auth.admin.deleteUser(userId)
        if (delErr) {
            // 【说清楚现在是什么状态】—— 一个建出来了、没有角色、而且删不掉的账号。
            return { error: t('permissions.errCreateRolledBackFailed', { 0: reason, 1: delErr.message, 2: email }) }
        }
        return { error: t('permissions.errCreateRolledBack', { 0: reason }) }
    }

    // 关联员工档案(可选)。走【普通客户端 + DEFINER 函数】,不用 service role ——
    // 这样 action.manage_permissions 与各个守卫仍然是真的在把关。
    if (form.employeeId) {
        const { error: linkErr } = await supabase.rpc('set_user_employee_link', {
            p_user_id: userId,
            p_employee_id: form.employeeId,
        })
        if (linkErr) return undo(await localize(linkErr.message))
    }

    // 【恰好一个角色】set_user_roles 收的是数组(权限是并集),这里只给一个。
    const { error: roleAssignErr } = await supabase.rpc('set_user_roles', {
        p_user_id: userId,
        p_role_ids: [form.roleId],
    })
    if (roleAssignErr) return undo(await localize(roleAssignErr.message))

    revalidatePath('/settings/accounts')
    return { success: true, email }
}

// ★ C-1:【setEmployeeLink 删掉了,它是死代码】原 inviteActions.ts 里带着它,
//   注释写着"供用户页的编辑面板使用" —— 实测【没有任何文件 import 过它】
//   (UserRow 走的是 ../accountsActions 的 saveUserRoles)。
//   把一段没人调的代码搬进新文件,等于给下一个人留一条假线索。
